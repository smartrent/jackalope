defmodule Hare.TortoiseClient do
  @moduledoc """
  The Tortoise client talks to Tortoise configured to use Amazon Web Service (AWS) IoT broker over a TLS
  connection.
  """

  use GenServer

  require Logger

  @publish_timeout 30_000
  # at least once
  @qos 1
  @max_connection_attempts 5
  @connection_retry_delay 5_000

  defmodule State do
    defstruct connection: nil,
              app_handler: nil,
              client_id: nil,
              connection_options: []
  end

  @doc "Start a Tortoise client"
  @spec start_link(any) :: GenServer.on_start()
  def start_link(init_args) do
    Logger.info("[Hare] Starting Tortoise client with #{inspect(init_args)}")
    GenServer.start_link(__MODULE__, init_args, name: __MODULE__)
  end

  @doc "Publish a message"
  @spec publish(String.t(), map()) :: :ok | {:ok, reference()} | {:error, atom}
  def publish(topic, payload, timeout \\ 60_000) do
    json_encoded_payload =
      case Jason.encode(payload) do
        {:ok, encoded_payload} ->
          encoded_payload

        {:error, reason} ->
          "Unable to encode: #{inspect(payload)} reason: #{inspect(reason)}"
      end

    GenServer.call(__MODULE__, {:publish, topic, json_encoded_payload}, timeout)
  end

  @doc "Subscribe the hub to a topic"
  @spec subscribe(String.t()) :: {:ok, reference()} | {:error, atom}
  def subscribe(topic) do
    GenServer.call(__MODULE__, {:subscribe, topic})
  end

  @doc "Unubscribe the hub from a topic"
  @spec unsubscribe(String.t()) :: {:ok, reference()} | {:error, atom}
  def unsubscribe(topic) do
    GenServer.call(__MODULE__, {:unsubscribe, topic})
  end

  @doc "Do we have an MQTT connection?"
  @spec connected?() :: boolean
  def connected?() do
    GenServer.call(__MODULE__, :connected?)
  end

  ### GenServer CALLBACKS

  @impl true
  def init(init_args) do
    app_handler = Keyword.get(init_args, :app_handler, Hare.DefaultAppHandler)
    client_id = Keyword.get(init_args, :client_id, :no_name)
    connection_options = Keyword.get(init_args, :connection_options, [])

    initial_state = %State{
      client_id: client_id,
      app_handler: app_handler,
      connection_options: connection_options
    }

    {:ok, initial_state, {:continue, :spawn_connection}}
  end

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

  def handle_call({:subscribe, topic}, _from, %State{connection: nil} = state) do
    Logger.warn("[Hare] Can't subscribe to #{inspect(topic)}: No connection")
    {:reply, {:error, :no_connection}, state}
  end

  def handle_call({:subscribe, topic}, _from, %State{client_id: client_id} = state) do
    Logger.debug("[Hare] Subscribing #{client_id} to #{inspect(topic)}")
    {:reply, Tortoise.Connection.subscribe(client_id, {topic, @qos}), state}
  end

  def handle_call({:unsubscribe, topic}, _from, %State{connection: nil} = state) do
    Logger.warn("[Hare] Can't unsubscribe from #{inspect(topic)}: No connection")
    {:reply, {:error, :no_connection}, state}
  end

  def handle_call({:unsubscribe, topic}, _from, %State{client_id: client_id} = state) do
    Logger.info("[Hare] Unsubscribing #{client_id} from topic #{inspect(topic)}")
    {:reply, Tortoise.Connection.unsubscribe(client_id, topic), state}
  end

  def handle_call({:publish, topic, payload}, _from, %State{client_id: client_id} = state) do
    {:reply, do_publish(topic, payload, client_id), state}
  end

  @impl true
  # Tortoise network status changes
  def handle_info(
        {{Tortoise, client_id}, :status, network_status},
        %State{client_id: client_id, app_handler: app_handler} = state
      ) do
    case network_status do
      :up ->
        Logger.info("[Hare] MQTT client is online (#{client_id})")
        apply(app_handler, :connection_status, [:up])
        {:noreply, state}

      :down ->
        Logger.info("[Hare] MQTT client is offline (#{client_id})")
        {:noreply, state}

      :terminating ->
        Logger.info("[Hare] MQTT client is terminating (#{client_id})")
        {:noreply, state}
    end
  end

  # result is :ok or {:error, reason}
  # reference is known from prior publish, subscribe or unsubscribe
  def handle_info(
        {{Tortoise, client_id}, reference, result},
        %State{app_handler: app_handler} = state
      ) do
    apply(app_handler, :tortoise_result, [client_id, reference, result])

    {:noreply, state}
  end

  defp do_publish(topic, payload, client_id) do
    Logger.info("[Hare] Publishing #{topic} with payload #{payload}")
    # Async publish
    case Tortoise.publish(client_id, topic, payload, qos: @qos, timeout: @publish_timeout) do
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
