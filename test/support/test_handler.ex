defmodule JackalopeTest.TestHandler do
  @moduledoc false

  @behaviour Jackalope.Handler

  @impl true
  def connection(status) do
    IO.inspect(status, label: __MODULE__.CONNECTION)
    :ok
  end

  @impl true
  def handle_message(topic, payload) do
    IO.inspect({topic, payload}, label: __MODULE__.HANDLE_MESSAGE)
    :ok
  end

  @impl true
  def subscription(status, topic) do
    IO.inspect({status, topic}, label: __MODULE__.HANDLE_ERROR)
    :ok
  end

  @impl true
  def handle_error(error) do
    IO.inspect(error, label: __MODULE__.HANDLE_ERROR)
    :ok
  end
end
