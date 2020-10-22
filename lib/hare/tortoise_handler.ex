defmodule Hare.TortoiseHandler do
  @moduledoc "Handles the callbacks from Tortoise"
  @behaviour Tortoise.Handler
  require Logger

  ### CALLBACKS from Tortoise

  def init(opts) do
    {:ok, opts}
  end

  def connection(conn_status, state) do
    app_handler = Keyword.fetch!(state, :app_handler)
    apply(app_handler, :connection_status, [conn_status])
    {:ok, state}
  end

  def subscription(:up, topic, state) do
    app_handler = Keyword.fetch!(state, :app_handler)
    apply(app_handler, :subscription, [:up, topic])
    {:ok, state}
  end

  def subscription(:down, topic, state) do
    app_handler = Keyword.fetch!(state, :app_handler)
    apply(app_handler, :subscription, [:down, topic])
    {:ok, state}
  end

  def handle_message(topic, payload_string, state) do
    app_handler = Keyword.fetch!(state, :app_handler)

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
