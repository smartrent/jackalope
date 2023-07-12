defmodule Jackalope.Handler.Logger do
  @moduledoc """
  A `Jackalope.Handler` that logs everything it sees

  This handler will be used by `Jackalope` if no `handler` has been
  specified in the option list passed to `Jackalope.start_link/1`.
  """

  @behaviour Jackalope.Handler

  require Logger

  @impl Jackalope.Handler
  def connection(status) do
    Logger.info("Connection status is: #{inspect(status)}")
  end

  @impl Jackalope.Handler
  def subscription(status, topic_filter) do
    Logger.info("Subscription change: #{inspect(topic_filter)} is #{inspect(status)}")
  end

  @impl Jackalope.Handler
  def handle_message(topic, payload) do
    Logger.info("Received #{inspect(topic)}: #{inspect(payload)}")
  end

  @impl Jackalope.Handler
  def handle_error(reason) do
    Logger.warning("Something bad happened: #{inspect(reason)}")
  end

  @impl Jackalope.Handler
  def last_will(), do: nil
end
