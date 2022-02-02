defmodule Jackalope.TortoiseClient do
  @moduledoc false

  # The Tortoise311 client talks to Tortoise311 configured to use Amazon Web
  # Service (AWS) IoT broker over a TLS connection.

  use GenServer

  alias Jackalope.Item
  alias Jackalope.Session

  require Logger

  defmodule State do
    @moduledoc false

    defstruct connection: nil,
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
  @spec publish(Item.t()) :: :ok | {:ok, reference()} | {:error, atom}
  def publish(%Item{} = item) do
    GenServer.call(__MODULE__, {:publish, item}, timeout: 60000)
  end

  @doc "Do we have an MQTT connection?"
  @spec connected?() :: boolean
  def connected?() do
    GenServer.call(__MODULE__, :connected?)
  end

  ### GenServer CALLBACKS

  @impl GenServer
  def init(opts) do
    case struct(%State{}, opts) do
      %State{client_id: nil} ->
        {:stop, :missing_client_id}

      %State{handler: nil} ->
        {:stop, :missing_handler}

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

      {:error, :timeout} ->
        Logger.warn("[Jackalope] Timed out trying to create MQTT client. Trying again.")

        {:noreply, state, {:continue, :spawn_connection}}

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

      {:error, :timeout} ->
        Logger.warn("[Jackalope] Timed out trying to subscribe to connection. Trying again.")
        {:noreply, state, {:continue, :subscribe_to_connection}}

      {:error, reason} when reason in [:timeout, :unknown_connection] ->
        {:stop, {:connection_failure, reason}, state}
    end
  end

  @impl GenServer
  def handle_call(:connected?, _from, %State{connection: pid} = state) do
    tortoise_state = is_pid(pid) and Process.alive?(pid)
    {:reply, tortoise_state, state}
  end

  def handle_call({:publish, item}, _from, %State{} = state) do
    {:reply, do_publish(state, item), state}
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
    Session.report_tortoise_result(reference, result)

    {:noreply, state}
  end

  defp do_publish(%State{client_id: client_id} = state, item) do
    qos = Keyword.get(item.opts, :qos, state.default_qos)
    Logger.info("[Jackalope] Publishing #{item.topic} with payload #{item.payload}")
    # Async publish
    case Tortoise311.publish(client_id, item.topic, item.payload, qos: qos, timeout: 5000) do
      :ok ->
        :ok

      {:ok, reference} ->
        {:ok, reference}

      {:error, reason} ->
        if function_exported?(state.handler, :handle_error, 1) do
          reason = {:publish_error, {item.topic, item.payload, item.opts}, reason}
          state.handler.handle_error(reason)
        end

        {:error, reason}
    end
  end
end
