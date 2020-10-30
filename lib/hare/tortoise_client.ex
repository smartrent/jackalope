defmodule Hare.TortoiseClient do
  @moduledoc """
  The Tortoise client talks to Tortoise configured to use Amazon Web Service (AWS) IoT broker over a TLS
  connection.
  """

  use GenServer

  require Logger

  defmodule State do
    defstruct connection: nil,
              hare_pid: nil,
              app_handler: nil,
              client_id: nil,
              connection_options: [],
              publish_timeout: 30_000,
              # at least once
              default_qos: 1
  end

  @doc "Start a Tortoise client"
  @spec start_link(any) :: GenServer.on_start()
  def start_link(init_args) do
    Logger.info("[Hare] Starting Tortoise client with #{inspect(init_args)}")
    GenServer.start_link(__MODULE__, init_args, name: __MODULE__)
  end

  @doc """
  Tell Tortoise to reconnect
  """
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

  @doc "Unubscribe the hub from a topic"
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

  @impl true
  def init(opts) do
    case struct(%State{hare_pid: Hare.whereis()}, opts) do
      %State{client_id: nil} ->
        {:stop, :missing_client_id}

      %State{app_handler: nil} ->
        {:stop, :missing_app_handler}

      %State{hare_pid: pid} when not is_pid(pid) ->
        {:stop, :missing_hare_process}

      %State{} = initial_state ->
        {:ok, initial_state, {:continue, :spawn_connection}}
    end
  end

  @impl true
  def handle_continue(:spawn_connection, %State{connection: nil} = state) do
    Logger.info("[Hare] Spawning Tortoise connection")
    # Attempt to spawn a tortoise connection to the MQTT server; the
    # tortoise will attempt to connect to the server, so we are not
    # fully up once we got the process
    handler = {Hare.TortoiseHandler, [app_handler: state.app_handler]}

    conn_opts =
      state.connection_options
      |> Keyword.put(:client_id, state.client_id)
      |> Keyword.put(:handler, handler)

    case Tortoise.Supervisor.start_child(ConnectionSupervisor, conn_opts) do
      {:ok, pid} ->
        state = %State{state | connection: pid}
        {:noreply, state, {:continue, :subscribe_to_connection}}

      {:error, {:already_started, pid}} ->
        state = %State{state | connection: pid}
        {:noreply, state, {:continue, :subscribe_to_connection}}

      {:error, reason} ->
        Logger.error("[Hare] Failed to create MQTT client: #{inspect(reason)}")
        {:stop, {:connection_failure, reason}, state}

      :ignore ->
        Logger.warn("[Hare] Starting Tortoise connection IGNORED!")
        {:noreply, state}
    end
  end

  def handle_continue(:spawn_connection, %State{connection: pid} = state) when is_pid(pid) do
    Logger.warn("[Hare] Already connected to MQTT broker. No need to connect.")
    {:noreply, state}
  end

  def handle_continue(:subscribe_to_connection, %State{connection: pid} = state)
      when is_pid(pid) do
    # Create an active subscription to the tortoise connection; this
    # will allow us to react to network up and down events as we will
    # get a Tortoise Event when the network status changes
    case Tortoise.Connection.connection(state.client_id, active: true) do
      {:ok, _connection} ->
        {:ok, _} = Tortoise.Events.register(state.client_id, :status)
        {:noreply, state}

      {:error, reason} when reason in [:timeout, :unknown_connection] ->
        {:stop, {:connection_failure, reason}, state}
    end
  end

  @impl true
  def handle_call(:connected?, _from, %State{connection: pid} = state) do
    tortoise_state = is_pid(pid) and Process.alive?(pid)
    {:reply, tortoise_state, state}
  end

  def handle_call({:subscribe, topic, _opts}, _from, %State{connection: nil} = state) do
    Logger.warn("[Hare] Can't subscribe to #{inspect(topic)}: No connection")
    {:reply, {:error, :no_connection}, state}
  end

  def handle_call({:subscribe, topic, opts}, _from, %State{client_id: client_id} = state) do
    qos = Keyword.get(opts, :qos, 1)
    Logger.debug("[Hare] Subscribing #{client_id} to #{inspect(topic)}")
    {:reply, Tortoise.Connection.subscribe(client_id, {topic, qos}), state}
  end

  def handle_call({:unsubscribe, topic_filter, _opts}, _from, %State{connection: nil} = state) do
    Logger.warn("[Hare] Can't unsubscribe from #{inspect(topic_filter)}: No connection")
    {:reply, {:error, :no_connection}, state}
  end

  def handle_call(
        {:unsubscribe, topic_filter, _opts},
        _from,
        %State{client_id: client_id} = state
      ) do
    Logger.info("[Hare] Unsubscribing #{client_id} from topic #{inspect(topic_filter)}")
    {:reply, Tortoise.Connection.unsubscribe(client_id, topic_filter), state}
  end

  def handle_call({:publish, topic, payload, opts}, _from, %State{} = state) do
    {:reply, do_publish(state, topic, payload, opts), state}
  end

  @impl true
  def handle_cast(:reconnect, %State{} = state) do
    Tortoise.Connection.disconnect(state.client_id)
    state = %State{state | connection: nil}
    {:noreply, state, {:continue, :spawn_connection}}
  end

  @impl true
  # Tortoise network status changes
  def handle_info(
        {{Tortoise, client_id}, :status, network_status},
        %State{client_id: client_id} = state
      ) do
    case network_status do
      :up ->
        Logger.info("[Hare] MQTT client is online (#{client_id})")
        {:noreply, state}

      :down ->
        Logger.info("[Hare] MQTT client is offline (#{client_id})")
        {:noreply, state}

      :terminating ->
        Logger.info("[Hare] MQTT client is terminating (#{client_id})")
        {:noreply, state}

      :terminated ->
        Logger.info("[Hare] MQTT client has terminated (#{client_id})")
        {:noreply, state}
    end
  end

  # Send the result to the Hare process; the Hare process will keep
  # track of the references, and it knowns about the type of
  # message--publish, subscribe, or unsubscribe--that the reference
  # relates to.
  def handle_info(
        {{Tortoise, _client_id}, reference, result},
        %State{} = state
      ) do
    send state.hare_pid, {:tortoise_result, reference, result}
    {:noreply, state}
  end

  defp do_publish(%State{client_id: client_id} = state, topic, payload, opts) do
    qos = Keyword.get(opts, :qos, state.default_qos)
    Logger.info("[Hare] Publishing #{topic} with payload #{payload}")
    # Async publish
    case Tortoise.publish(client_id, topic, payload, qos: qos, timeout: client_id) do
      :ok ->
        :ok

      {:ok, reference} ->
        {:ok, reference}

      {:error, reason} ->
        Logger.warn(
          "[Hare] Failed to publish #{inspect(topic)} with #{inspect(payload)}: #{reason}"
        )

        {:error, reason}
    end
  end
end
