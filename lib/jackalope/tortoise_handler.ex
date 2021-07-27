defmodule Jackalope.TortoiseHandler do
  @moduledoc false

  @behaviour Tortoise.Handler

  require Logger

  alias __MODULE__, as: State

  defstruct jackalope_pid: nil, handler: nil, default_last_will: nil

  @impl true
  def init(opts) do
    initial_state = %State{
      handler: Keyword.fetch!(opts, :handler),
      jackalope_pid: Keyword.fetch!(opts, :jackalope_pid),
      default_last_will: Keyword.get(opts, :last_will)
    }

    {:ok, initial_state}
  end

  @impl true
  def last_will(%State{} = state) do
    last_will = apply(state.handler, :last_will, []) || state.default_last_will
    packaged_last_will = package_last_will(last_will)

    {{:ok, packaged_last_will}, state}
  end

  @impl true
  def connection(status, %State{} = state) do
    # inform the jackalope process about the connection status change
    send(state.jackalope_pid, {:connection_status, status})

    if function_exported?(state.handler, :connection, 1) do
      _ignored = apply(state.handler, :connection, [status])
    end

    {:ok, state}
  end

  @impl true
  def subscription(status, topic_filter, %State{} = state) when status in [:up, :down] do
    if function_exported?(state.handler, :subscription, 2) do
      _ignored = apply(state.handler, :subscription, [status, topic_filter])
    end

    # Jackalope itself will track the subscription status by observing
    # the responses to subscribe and unsubscribe messages, so we don't
    # need to send a message to jackalope here.
    {:ok, state}
  end

  @impl true
  def handle_message(topic_levels, payload_string, %State{handler: handler} = state) do
    case Jason.decode(payload_string) do
      {:ok, payload} ->
        # Dispatch to the handle message callback on the jackalope handler
        apply(handler, :handle_message, [topic_levels, payload])
        {:ok, state}

      {:error, reason} ->
        # Dispatch to the handle error callback on the jackalope handler if
        # implemented
        if function_exported?(handler, :handle_error, 1) do
          reason = {:payload_decode_error, reason, {topic_levels, payload_string}}
          apply(handler, :handle_error, [reason])
        end

        {:ok, state}
    end
  end

  @impl true
  def terminate(_some_reason, _state) do
    Logger.info("[Jackalope] Tortoise reports termination")
    :ok
  end

  defp package_last_will(last_will) do
    if last_will != nil do
      payload_term = Keyword.get(last_will, :payload)

      %Tortoise.Package.Publish{
        topic: Keyword.fetch!(last_will, :topic),
        payload: encode_last_will_payload(payload_term),
        qos: Keyword.get(last_will, :qos, 0),
        retain: false
      }
    else
      nil
    end
  end

  defp encode_last_will_payload(nil), do: nil
  defp encode_last_will_payload(term), do: Jason.encode!(term)
end
