defmodule Hare.Handler.Logger do
  require Logger

  @behaviour Hare.Handler

  def connection(status) do
    Logger.info("Connection status is: #{inspect(status)}")
  end

  def subscription(status, topic_filter) do
    Logger.info("Subscription change: #{inspect(topic_filter)} is #{inspect(status)}")
  end

  def handle_message(topic, payload) do
    Logger.info("Received #{inspect(topic)}: #{inspect(payload)}")
  end

  def handle_error(reason) do
    Logger.warn("Something bad happened: #{reason}")
  end
end
