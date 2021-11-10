defmodule Jackalope.Watchdog do
  @moduledoc false

  # Keeps a heartbeat on the Tortoise connection and crashes if
  # Tortoise becomes unresponsive.

  use GenServer
  require Logger

  defmodule State do
    @moduledoc false

    defstruct client_id: nil,
              # until proved otherwise
              alive?: true,
              heartbeat_delay: 120_000,
              max_wait: 30_000,
              alive_timeout: 5_000
  end

  @doc "FOR TESTING ONLY - Causes a crash"
  @spec crash() :: :ok
  def crash() do
    GenServer.call(__MODULE__, :crash)
  end

  @doc "Whether the MQTT connection is live"
  @spec mqtt_alive?() :: boolean
  def mqtt_alive?() do
    GenServer.call(__MODULE__, :alive?)
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    Logger.info("[Jackalope] Starting Tortoise watchdog")
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    case struct(State, opts) do
      %State{client_id: nil} ->
        {:stop, :missing_client_id}

      %State{} = initial_state ->
        {:ok, initial_state, {:continue, :schedule_heartbeat}}
    end
  end

  @impl GenServer
  def handle_continue(:schedule_heartbeat, %State{heartbeat_delay: timeout} = state) do
    Process.send_after(self(), :heartbeat, timeout)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:alive?, _from, %State{alive?: alive?} = state) do
    {:reply, alive?, state}
  end

  def handle_call(:crash, _from, state) do
    raise "CRASH!!!"
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:heartbeat, %State{client_id: client_id} = state) do
    try do
      answer =
        Task.async(fn -> ping_tortoise(client_id, state.alive_timeout) end)
        |> Task.await(state.max_wait)

      state = %State{state | alive?: answer == :ok}
      {:noreply, state, {:continue, :schedule_heartbeat}}
    catch
      :exit, reason ->
        # Crash if the ping message was apparently not handled by Tortoise.Connection,
        # indicating that the processing of its message queue is somehow suspended
        Logger.warn(
          "[Jackalope] Watchdog - Tortoise.Connection is unresponsive: #{inspect(reason)}"
        )

        raise "CRASH!"
    end
  end

  defp ping_tortoise(client_id, timeout) do
    case Tortoise.Connection.ping_sync(client_id, timeout) do
      {:ok, _latency} ->
        :ok

      {:error, reason} ->
        Logger.warn("[Jackalope] Watchdog - Connection failed to ping MQTT broker: #{reason}")
        {:error, reason}
    end
  end
end
