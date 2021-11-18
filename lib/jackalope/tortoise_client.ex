defmodule Jackalope.TortoiseClient do
  @moduledoc false

  # The Tortoise311 client talks to Tortoise311 configured to use Amazon Web
  # Service (AWS) IoT broker over a TLS connection.

  use GenServer

  require Logger

  defmodule State do
    @moduledoc false

    defstruct connection: nil,
              jackalope_pid: nil,
              handler: nil,
              client_id: nil,
              connection_options: [],
              publish_timeout: 30_000,
              last_will: nil,
              # at least once
              default_qos: 1
  end

  @doc "Start a Tortoise311 client"
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(init_args) do
    GenServer.start_link(__MODULE__, init_args, name: __MODULE__)
  end

  @doc """
  Tell Tortoise311 to reconnect
  """
  @spec reconnect() :: :ok
  def reconnect() do
    GenServer.cast(__MODULE__, :reconnect)
  end

  @doc "Publish a message"
  @spec publish(String.t(), map(), opts :: Keyword.t() | non_neg_integer) ::
          :ok | {:ok, reference()} | {:error, atom}
  def publish(topic, payload, opts \\ [])

  def publish(topic, payload, opts) when is_list(opts) do
    {client_opts, opts} = Keyword.split(opts, [:timeout])
    timeout = Keyword.get(client_opts, :timeout, 60_000)

    json_payload =
      case Jason.encode(payload) do
        {:ok, encoded_payload} ->
          encoded_payload

        {:error, reason} ->
          "Unable to encode: #{inspect(payload)} reason: #{inspect(reason)}"
      end

    GenServer.call(__MODULE__, {:publish, topic, json_payload, opts}, timeout)
  end

  def publish(topic, payload, timeout) when is_integer(timeout) and timeout >= 0 do
    # lift timeout to options
    publish(topic, payload, timeout: timeout)
  end

  @doc "Subscribe the hub to a topic"
  @spec subscribe(String.t(), opts :: Keyword.t()) :: {:ok, reference()} | {:error, atom}
  def subscribe(topic, opts \\ []) do
    opts = Keyword.put_new(opts, :qos, 1)
    GenServer.call(__MODULE__, {:subscribe, topic, opts})
  end

  @doc "Unsubscribe the hub from a topic"
  @spec unsubscribe(String.t(), opts :: Keyword.t()) :: {:ok, reference()} | {:error, atom}
  def unsubscribe(topic_filter, opts \\ []) do
    GenServer.call(__MODULE__, {:unsubscribe, topic_filter, opts})
  end

  @doc "Do we have an MQTT connection?"
  @spec connected?() :: boolean
  def connected?() do
    GenServer.call(__MODULE__, :connected?)
  end

  ### GenServer CALLBACKS

  @impl GenServer
  def init(opts) do
    case struct(%State{jackalope_pid: Jackalope.Session.whereis()}, opts) do
      %State{client_id: nil} ->
        {:stop, :missing_client_id}

      %State{handler: nil} ->
        {:stop, :missing_handler}

      %State{jackalope_pid: pid} when not is_pid(pid) ->
        {:stop, :missing_jackalope_process}

      %State{} = initial_state ->
        {:ok, initial_state, {:continue, :spawn_connection}}
    end
  end

  @impl GenServer
  def handle_continue(:spawn_connection, %State{connection: nil} = state) do
    # Attempt to spawn a tortoise connection to the MQTT server; the
    # tortoise will attempt to connect to the server, so we are not
    # fully up once we got the process
    handler_opts = [
      handler: state.handler,
      jackalope_pid: state.jackalope_pid,
      last_will: state.last_will
    ]

    tortoise_handler = {
      Jackalope.TortoiseHandler,
      handler_opts
    }

    conn_opts =
      state.connection_options
      |> Keyword.put(:client_id, state.client_id)
      |> Keyword.put(:handler, tortoise_handler)

    case Tortoise311.Supervisor.start_child(ConnectionSupervisor, conn_opts) do
      {:ok, pid} ->
        state = %State{state | connection: pid}
        {:noreply, state, {:continue, :subscribe_to_connection}}

      {:error, {:already_started, pid}} ->
        state = %State{state | connection: pid}
        {:noreply, state, {:continue, :subscribe_to_connection}}

      {:error, reason} ->
        Logger.error("[Jackalope] Failed to create MQTT client: #{inspect(reason)}")
        {:stop, {:connection_failure, reason}, state}

      :ignore ->
        Logger.warn("[Jackalope] Starting Tortoise311 connection IGNORED!")
        {:noreply, state}
    end
  end

  def handle_continue(:spawn_connection, %State{connection: pid} = state) when is_pid(pid) do
    Logger.warn("[Jackalope] Already connected to MQTT broker. No need to connect.")
    {:noreply, state}
  end

  def handle_continue(:subscribe_to_connection, %State{connection: pid} = state)
      when is_pid(pid) do
    # Create an active subscription to the tortoise connection; this
    # will allow us to react to network up and down events as we will
    # get a Tortoise311 Event when the network status changes
    case Tortoise311.Connection.connection(state.client_id, active: true) do
      {:ok, _connection} ->
        {:ok, _} = Tortoise311.Events.register(state.client_id, :status)
        {:noreply, state}

      {:error, reason} when reason in [:timeout, :unknown_connection] ->
        {:stop, {:connection_failure, reason}, state}
    end
  end

  @impl GenServer
  def handle_call(:connected?, _from, %State{connection: pid} = state) do
    tortoise_state = is_pid(pid) and Process.alive?(pid)
    {:reply, tortoise_state, state}
  end

  def handle_call({:subscribe, topic, _opts}, _from, %State{connection: nil} = state) do
    Logger.warn("[Jackalope] Can't subscribe to #{inspect(topic)}: No connection")
    {:reply, {:error, :no_connection}, state}
  end

  def handle_call({:subscribe, topic, opts}, _from, %State{client_id: client_id} = state) do
    qos = Keyword.get(opts, :qos, 1)
    Logger.debug("[Jackalope] Subscribing #{client_id} to #{inspect(topic)}")
    {:reply, Tortoise311.Connection.subscribe(client_id, {topic, qos}), state}
  end

  def handle_call({:unsubscribe, topic_filter, _opts}, _from, %State{connection: nil} = state) do
    Logger.warn("[Jackalope] Can't unsubscribe from #{inspect(topic_filter)}: No connection")
    {:reply, {:error, :no_connection}, state}
  end

  def handle_call(
        {:unsubscribe, topic_filter, _opts},
        _from,
        %State{client_id: client_id} = state
      ) do
    Logger.info("[Jackalope] Unsubscribing #{client_id} from topic #{inspect(topic_filter)}")
    {:reply, Tortoise311.Connection.unsubscribe(client_id, topic_filter), state}
  end

  def handle_call({:publish, topic, payload, opts}, _from, %State{} = state) do
    {:reply, do_publish(state, topic, payload, opts), state}
  end

  @impl GenServer
  def handle_cast(:reconnect, %State{} = state) do
    Tortoise311.Connection.disconnect(state.client_id)
    state = %State{state | connection: nil}
    {:noreply, state, {:continue, :spawn_connection}}
  end

  @impl GenServer
  # Tortoise311 network status changes
  def handle_info(
        {{Tortoise311, client_id}, :status, network_status},
        %State{client_id: client_id} = state
      ) do
    case network_status do
      :up ->
        {:noreply, state}

      status when status in [:down, :terminating, :terminated] ->
        {:noreply, state}
    end
  end

  # Send the result to the Jackalope process; the Jackalope process
  # will keep track of the references, and it knowns about the type of
  # message--publish, subscribe, or unsubscribe--that the reference
  # relates to.
  def handle_info(
        {{Tortoise311, _client_id}, reference, result},
        %State{} = state
      ) do
    send(state.jackalope_pid, {:tortoise_result, reference, result})
    {:noreply, state}
  end

  defp do_publish(%State{client_id: client_id} = state, topic, payload, opts) do
    qos = Keyword.get(opts, :qos, state.default_qos)
    Logger.info("[Jackalope] Publishing #{topic} with payload #{payload}")
    # Async publish
    case Tortoise311.publish(client_id, topic, payload, qos: qos, timeout: 5000) do
      :ok ->
        :ok

      {:ok, reference} ->
        {:ok, reference}

      {:error, reason} ->
        if function_exported?(state.handler, :handle_error, 1) do
          reason = {:publish_error, {topic, payload, opts}, reason}
          apply(state.handler, :handle_error, [reason])
        end

        {:error, reason}
    end
  end
end
