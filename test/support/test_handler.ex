defmodule JackalopeTest.TestHandler do
  @moduledoc false

  @behaviour Jackalope.Handler

  require Logger

  defp label(%Macro.Env{module: module, function: {function, _arity}} = _env) do
    "#{module}.#{function}"
  end

  @impl Jackalope.Handler
  def connection(status) do
    Logger.debug("#{label(__ENV__)}: #{inspect(status)}")
  end

  @impl Jackalope.Handler
  def handle_message(topic, payload) do
    Logger.debug("#{label(__ENV__)}: #{inspect({topic, payload})}")
  end

  @impl Jackalope.Handler
  def subscription(status, topic) do
    Logger.debug("#{label(__ENV__)}: #{inspect({status, topic})}")
  end

  @impl Jackalope.Handler
  def handle_error(error) do
    Logger.debug("#{label(__ENV__)}: #{inspect(error)}")
  end

  @impl Jackalope.Handler
  def last_will() do
    Logger.debug("#{label(__ENV__)}: No update to last will")

    nil
  end
end
