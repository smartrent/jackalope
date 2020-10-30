defmodule Hare.TortoiseHandler do
  @moduledoc "Handles the callbacks from Tortoise"
  @behaviour Tortoise.Handler
  require Logger

  alias __MODULE__, as: State

  defstruct app_handler: nil, hare_pid: nil

  ### CALLBACKS from Tortoise

  def init(opts) do
    initial_state = %State{
      app_handler: Keyword.fetch!(opts, :app_handler),
      hare_pid: Hare.whereis()
    }

    {:ok, initial_state}
  end

  def connection(status, %State{} = state) do
    send state.hare_pid, {:connection_status, status}
    {:ok, state}
  end

  def subscription(:up, topic, %State{} = state) do
    apply(state.app_handler, :subscription, [:up, topic])
    {:ok, state}
  end

  def subscription(:down, topic, %State{} = state) do
    apply(state.app_handler, :subscription, [:down, topic])
    {:ok, state}
  end

  def handle_message(topic, payload_string, %State{app_handler: app_handler} = state) do
    case Jason.decode(payload_string) do
      {:ok, payload} ->
        apply(app_handler, :message_received, [topic, payload])

      {:error, _reason} ->
        apply(app_handler, :invalid_payload, [topic, payload_string])
    end

    {:ok, state}
  end

  def terminate(_some_reason, _state) do
    Logger.info("[Hare] Tortoise reports termination")
    :ok
  end
end
