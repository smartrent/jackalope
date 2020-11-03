defmodule Hare.TortoiseHandler do
  @moduledoc false

  @behaviour Tortoise.Handler

  require Logger

  alias __MODULE__, as: State

  defstruct hare_pid: nil, handler: nil

  @impl true
  def init(opts) do
    initial_state = %State{
      handler: Keyword.fetch!(opts, :handler),
      hare_pid: Hare.whereis()
    }

    {:ok, initial_state}
  end

  @impl true
  def connection(status, %State{} = state) do
    # inform the hare process about the connection status change
    send(state.hare_pid, {:connection_status, status})

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

    # Hare itself will track the subscription status by observing the
    # responses to subscribe and unsubscribe messages, so we don't
    # need to send a message to hare here.
    {:ok, state}
  end

  @impl true
  def handle_message(topic, payload_string, %State{handler: handler} = state) do
    case Jason.decode(payload_string) do
      {:ok, payload} ->
        # Dispatch to the handle message callback on the hare handler
        apply(handler, :handle_message, [topic, payload])
        {:ok, state}

      {:error, _reason} ->
        # Dispatch to the handle error callback on the hare handler if
        # implemented
        if function_exported?(handler, :handle_error, 1) do
          reason = {:payload_decode_error, {topic, payload_string}}
          apply(handler, :handle_error, [reason])
        end

        {:ok, state}
    end
  end

  @impl true
  def terminate(_some_reason, _state) do
    Logger.info("[Hare] Tortoise reports termination")
    :ok
  end
end
