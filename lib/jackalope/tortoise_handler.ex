defmodule Jackalope.TortoiseHandler do
  @moduledoc false

  @behaviour Tortoise.Handler

  require Logger

  alias __MODULE__, as: State

  defstruct jackalope_pid: nil, handler: nil

  @impl true
  def init(opts) do
    initial_state = %State{
      handler: Keyword.fetch!(opts, :handler),
      jackalope_pid: Keyword.fetch!(opts, :jackalope_pid)
    }

    {:ok, initial_state}
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

      {:error, _reason} ->
        # Dispatch to the handle error callback on the jackalope handler if
        # implemented
        if function_exported?(handler, :handle_error, 1) do
          reason = {:payload_decode_error, {topic_levels, payload_string}}
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
end
