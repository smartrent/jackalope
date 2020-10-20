defmodule Hare.DefaultAppHandler do
  @moduledoc "Default app handler"

  @behaviour Hare.AppHandler
  require Logger

  @impl true
  def tortoise_connection_options() do
    []
  end

  @impl true
  def client_id(), do: :no_name

  @impl true
  def connection_status(status) do
    Logger.info("[Hare] Connection status is #{inspect(status)}")
    :ok
  end

  @impl true
  def tortoise_result(client_id, reference, result) do
    Logger.info(
      "[Hare] Tortoise result for client #{inspect(client_id)} referenced by #{inspect(reference)} is #{
        inspect(result)
      }"
    )

    :ok
  end

  @impl true
  def subscription(status, topic) do
    Logger.info("[Hare] Requested subscription #{inspect(status)} for topic #{inspect(topic)}")
    :ok
  end

  @impl true
  def message_received(client_id, topic, payload) do
    Logger.info(
      "[Hare] Tortoise received message with topic #{inspect(topic)} and payload #{
        inspect(payload)
      } for client #{inspect(client_id)}"
    )

    :ok
  end

  @impl true
  def invalid_payload(client_id, topic, payload) do
    Logger.info(
      "[Hare] Tortoise received an invalid message with topic #{inspect(topic)} and payload #{
        inspect(payload)
      } for client #{inspect(client_id)}"
    )

    :ok
  end
end
