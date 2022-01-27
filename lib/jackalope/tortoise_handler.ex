defmodule Jackalope.TortoiseHandler do
  @moduledoc false

  @behaviour Tortoise311.Handler

  alias __MODULE__, as: State
  alias Jackalope.Session

  require Logger

  defstruct handler: nil, default_last_will: nil

  @impl Tortoise311.Handler
  def init(opts) do
    initial_state = %State{
      handler: Keyword.fetch!(opts, :handler),
      default_last_will: Keyword.get(opts, :last_will)
    }

    {:ok, initial_state}
  end

  @impl Tortoise311.Handler
  def last_will(%State{} = state) do
    last_will = state.handler.last_will() || state.default_last_will
    packaged_last_will = package_last_will(last_will)

    {{:ok, packaged_last_will}, state}
  end

  @impl Tortoise311.Handler
  def connection(status, %State{} = state) do
    # inform the jackalope process about the connection status change
    Session.report_connection_status(status)

    if function_exported?(state.handler, :connection, 1) do
      _ignored = state.handler.connection(status)
    end

    {:ok, state}
  end

  @impl Tortoise311.Handler
  def subscription(status, topic_filter, %State{} = state) when status in [:up, :down] do
    if function_exported?(state.handler, :subscription, 2) do
      _ignored = state.handler.subscription(status, topic_filter)
    end

    {:ok, state}
  end

  @impl Tortoise311.Handler
  def handle_message(topic_levels, payload, %State{handler: handler} = state) do
    handler.handle_message(topic_levels, payload)
    {:ok, state}
  end

  @impl Tortoise311.Handler
  def terminate(_some_reason, _state) do
    Logger.info("[Jackalope] Tortoise311 reports termination")
    :ok
  end

  defp package_last_will(last_will) do
    if last_will != nil do
      last_will_payload = Keyword.get(last_will, :payload)

      %Tortoise311.Package.Publish{
        topic: Keyword.fetch!(last_will, :topic),
        payload: last_will_payload,
        qos: Keyword.get(last_will, :qos, 0),
        retain: false
      }
    else
      nil
    end
  end
end
