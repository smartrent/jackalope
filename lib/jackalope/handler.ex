defmodule Jackalope.Handler do
  @moduledoc """
  Behaviour defining callbacks trigged during the MQTT life-cycle

  The jackalope handler is stateless, so if state is needed one could
  route the messages to stateful processes, and inform the system
  about connection and subscription state.

  Most of the callbacks are optional.
  """

  @type topic :: Tortoise.topic()
  @type topic_filter :: Tortoise.topic_filter()
  @type payload :: term()

  @doc """
  Called when the MQTT connection changes status

  This can be used to inform other parts of the system about the state
  of the connection; up or down?
  """
  @callback connection(status :: :up | :down) :: any()

  @doc """
  Called when a topic filter subscription state changes

  This can be used to inform other parts of the system that we should
  (or shouldn't) expect messages received on the given `topic_filter`.
  """
  @callback subscription(status :: :up | :down, topic_filter) :: any()

  @doc """
  Called when receiving a message matching one of the subscriptions

  The callback will receive two arguments; the MQTT topic in list
  form, where each of the topic levels are an item. This allows us to
  pattern match on topic filters with wildcards.

  The payload should be a term; we at this point the message will have
  been run through a JSON decoder. If the JSON decode should fail the
  optional `handle_error/1` callback would have been triggered
  instead.
  """
  @callback handle_message(topic, payload) :: any()

  @doc """
  Handle errors produced by Jackalope that should be reacted to
  """
  @callback handle_error(reason) :: any()
            when reason:
                   {:payload_decode_error, {topic, payload_string :: String.t()}}
                   | {:publish_error, {topic, payload, opts}, error_reason :: term}
                   | {:publish_error, jackalope_work_order :: term, :ttl_expired},
                 opts: Keyword.t()

  @optional_callbacks connection: 1,
                      subscription: 2,
                      handle_error: 1
end
