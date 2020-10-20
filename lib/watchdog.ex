defmodule Hare.Watchdog do
  @moduledoc "Keeps a heartbeat on the Tortoise connection and crashes if Tortoise becomes unresponsive."

  use GenServer
  require Logger

  @heartbeat_delay 120_000
  @max_wait 30_000
  @alive_timeout 5_000

  defmodule State do
    defstruct client_id: nil,
              # until proved otherwise
              alive?: true
  end

  @doc "FOR TESTING ONLY - Causes a crash"
  def crash() do
    GenServer.call(__MODULE__, :crash)
  end

  @doc "Whether the MQTT connection is live"
  @spec mqtt_alive?() :: boolean
  def mqtt_alive? do
    GenServer.call(__MODULE__, :alive?)
  end

  def start_link(opts) do
    Logger.info("[Hare] Starting Tortoise watchdog")
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    client_id = Keyword.get(opts, :client_id, :no_name)
    Process.send_after(self(), :heartbeat, @heartbeat_delay)
    {:ok, %State{client_id: client_id}}
  end

  @impl true
  def handle_call(:alive?, _from, %State{alive?: alive?} = state) do
    {:reply, alive?, state}
  end

  def handle_call(:crash, _from, state) do
    raise "CRASH!!!"
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:heartbeat, %State{client_id: client_id} = state) do
    response =
      try do
        answer =
          Task.async(fn -> ping_tortoise(client_id) end)
          |> Task.await(@max_wait)

        Process.send_after(self(), :heartbeat, @heartbeat_delay)
        answer
      catch
        :exit, reason ->
          # Crash if the ping message was apparently not handled by Tortoise.Connection,
          # indicating that the processing of its message queue is somehow suspended
          Logger.warn("[Hare] Watchdog - Tortoise.Connection is unresponsive: #{inspect(reason)}")

          raise "CRASH!"
      end

    alive? = response == :ok
    {:noreply, %State{state | alive?: alive?}}
  end

  defp ping_tortoise(client_id) do
    case Tortoise.Connection.ping_sync(client_id, @alive_timeout) do
      {:ok, _ref} ->
        Logger.info("[Hare] Watchdog - Connection to MQTT broker is alive")
        :ok

      {:error, reason} ->
        Logger.warn("[Hare] Watchdog - Connection failed to ping MQTT broker: #{reason}")
        {:error, reason}
    end
  end
end
