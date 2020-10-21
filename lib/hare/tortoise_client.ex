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

  @doc "Connect via Tortoise to MQTT broker"
  @spec connect(non_neg_integer) ::
          :ok
  def connect(attempts \\ 0) do
    GenServer.cast(__MODULE__, {:connect, attempts})
  end

  @doc "Publish a message"
  @spec publish(String.t(), map()) :: :ok | {:ok, reference()} | {:error, atom}
  def publish(topic, payload) do
    GenServer.call(__MODULE__, {:publish, topic, payload}, 60_000)
  end

  @doc "Subscribe the hub to a topic"
  @spec subscribe({String.t() | atom, integer}) :: {:ok, reference()} | {:error, atom}
  def subscribe(topic) do
    GenServer.call(__MODULE__, {:subscribe, topic})
  end

  @doc "Unubscribe the hub from a topic"
  @spec unsubscribe(String.t() | atom | integer) :: {:ok, reference()} | {:error, atom}
  def unsubscribe(topics) do
    GenServer.call(__MODULE__, {:unsubscribe, topics})
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

    {:ok,
     %State{
       client_id: client_id,
       app_handler: app_handler,
       connection_options: connection_options
     }}
  end

  @impl true
  def handle_cast(
        {:connect, attempts},
        %State{
          connection: nil,
          client_id: client_id,
          app_handler: app_handler,
          connection_options: connection_options
        } = state
      ) do
    Logger.info("[Hare] Connecting Tortoise (#{attempts}/#{@max_connection_attempts})")

    tortoise_connection_options =
      Keyword.put(connection_options, :client_id, client_id)
      |> Keyword.put(:handler, {Hare.TortoiseHandler, [app_handler: app_handler]})

    case Tortoise.Supervisor.start_child(
           ConnectionSupervisor,
           tortoise_connection_options
         ) do
      {:error, {:already_started, pid}} ->
        Logger.info("[Hare] Already connected to #{inspect(pid)}")
        apply(app_handler, :connection_status, [:up])
        {:noreply, %State{state | connection: pid}}

      {:error, reason} ->
        Logger.warn("[Hare] Failed to connect to MQTT broker: #{inspect(reason)}. Trying again.")

        if attempts > @max_connection_attempts do
          raise "Failed to connect to MQTT broker"
        else
          # TODO - Should we let it crash on first failed connection attempt? Is there value in retrying, after a delay?
          Process.sleep(@connection_retry_delay)
          connect(attempts + 1)
          {:noreply, state}
        end

      {:ok, pid} ->
        Logger.info("[Hare] Connected with #{inspect(pid)}")
        {:noreply, %State{state | connection: pid}}

      {:ok, pid, _} ->
        Logger.info("[Hare] Connected with #{inspect(pid)}")
        {:noreply, %State{state | connection: pid}}

      :ignore ->
        Logger.warn("[Hare] Starting Tortoise connection IGNORED!")
        {:noreply, state}
    end
  end

  def handle_cast({:connect, _attempts}, state) do
    Logger.warn("[Hare] Already connected to MQTT broker. No need to connect.")
    {:noreply, state}
  end

  @impl true
  def handle_call(:connected?, _from, %State{connection: pid} = state) do
    {:reply, pid != nil, state}
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
    payload_j =
      case Jason.encode(payload) do
        {:ok, encoded_payload} ->
          encoded_payload

        {:error, reason} ->
          "Unable to encode: #{inspect(payload)} reason: #{inspect(reason)}"
      end

    Logger.info("[Hare] Publishing #{topic} with payload #{payload_j}")
    # Async publish
    case Tortoise.publish(client_id, topic, payload_j, qos: @qos, timeout: @publish_timeout) do
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
