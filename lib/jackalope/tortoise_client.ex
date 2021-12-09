defmodule Jackalope.TortoiseClient do
  @moduledoc false

  # The Tortoise311 client talks to Tortoise311 configured to use Amazon Web
  # Service (AWS) IoT broker over a TLS connection.

  use GenServer

  require Logger

  @telemetry_delay 30_000

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
              default_qos: 1,
              socket_stats: %{socket: nil, last_stats: []}
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
        {:ok, initial_state, {:continue, :start_telemetry}}
    end
  end

  def handle_continue(:start_telemetry, state) do
    send(self(), :capture_telemetry)
    {:noreply, state, {:continue, :spawn_connection}}
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

  def handle_call({:publish, topic, payload, opts}, _from, %State{} = state) do
    {:reply, do_publish(state, topic, payload, opts), state}
  end

  @impl GenServer
  def handle_cast(:reconnect, %State{} = state) do
    updated_state = capture_telemetry(state)
    Tortoise311.Connection.disconnect(state.client_id)
    {:noreply, %State{updated_state | connection: nil}, {:continue, :spawn_connection}}
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

  def handle_info(:capture_telemetry, state) do
    Process.send_after(self(), :capture_telemetry, @telemetry_delay)
    {:noreply, capture_telemetry(state)}
  end

  defp capture_telemetry(state) do
    client_id = state.client_id
    registered_name = Tortoise311.Registry.via_name(Tortoise311.Connection, client_id)

    case Tortoise311.Registry.meta(registered_name) do
      {:ok, {_transport, socket}} ->
        case ssl_socket_stats(socket) do
          {:ok, stats} ->
            Logger.debug("[Jackalope] inet stats #{inspect(stats)} for socket #{inspect(socket)}")
            {received, sent} = new_stats(stats, state.socket_stats, socket)
            Logger.debug("[Jackalope] Received #{received} bytes and sent #{sent} bytes")

            :telemetry.execute([:jackalope, :transmission], %{
              received: received,
              sent: sent,
              sent_and_received: received + sent
            })

            %State{state | socket_stats: %{socket: socket, last_stats: stats}}

          other ->
            Logger.warn("[Jackalope] Failed to get socket stats: #{inspect(other)}")
            state
        end

      other ->
        Logger.warn("[Jackalope] Failed to capture telemetry on socket: #{inspect(other)}")
        state
    end
  end

  defp ssl_socket_stats({:sslsocket, _, _} = socket), do: :ssl.getstat(socket)

  defp ssl_socket_stats(socket) do
    Logger.warn("[Jackalope] Not an SSL socket #{inspect(socket)}")
    {:error, :not_ssl_socket}
  end

  defp new_stats(stats, socket_stats, socket) do
    if socket == socket_stats.socket do
      {stats[:recv_oct] - Keyword.get(socket_stats.last_stats, :recv_oct, 0),
       stats[:send_oct] - Keyword.get(socket_stats.last_stats, :send_oct, 0)}
    else
      {stats[:recv_oct], stats[:send_oct]}
    end
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
