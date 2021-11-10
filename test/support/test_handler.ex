defmodule JackalopeTest.TestHandler do
  @moduledoc false

  @behaviour Jackalope.Handler

  @impl Jackalope.Handler
  def connection(status) do
    IO.inspect(status, label: __MODULE__.CONNECTION)
    :ok
  end

  @impl Jackalope.Handler
  def handle_message(topic, payload) do
    IO.inspect({topic, payload}, label: __MODULE__.HANDLE_MESSAGE)
    :ok
  end

  @impl Jackalope.Handler
  def subscription(status, topic) do
    IO.inspect({status, topic}, label: __MODULE__.HANDLE_ERROR)
    :ok
  end

  @impl Jackalope.Handler
  def handle_error(error) do
    IO.inspect(error, label: __MODULE__.HANDLE_ERROR)
    :ok
  end

  @impl Jackalope.Handler
  def last_will() do
    IO.inspect("No update to last will", label: __MODULE__.LAST_WILL)
    nil
  end
end
