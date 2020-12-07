defmodule Jackalope.Handler do
  @moduledoc """
  Behaviour defining callbacks triggered during the MQTT life-cycle

  The jackalope handler is stateless, so if state is needed one could
  route the messages to stateful processes, and inform the system
  about connection and subscription state.

  Most of the callbacks are optional.
  """

  @type topic :: Tortoise.topic()
  @type topic_filter :: Tortoise.topic_filter()
  @type topic_levels :: [String.t()]
  @type payload :: term()

  @doc """
  Called when the MQTT connection changes status

  This can be used to inform other parts of the system about the state
  of the connection; possible values are `:up` and `:down`, where up
  means that the MQTT client has a connection to the broker; down
  means that the connection has been dropped.
  """
  @callback connection(status :: :up | :down) :: any()

  @doc """
  Called when a topic filter subscription state changes

  This can be used to inform other parts of the system that we should
  (or shouldn't) expect messages received on the given `topic_filter`.

  The status values are `:up` and `:down`, where up means that the
  broker has accepted a subscription request to the specific
  `topic_filter`, and down means that the broker has accepted an
  unsubscribe request.
  """
  @callback subscription(status :: :up | :down, topic_filter) :: any()

  @doc """
  Called when receiving a message matching one of the subscriptions

  The callback will receive two arguments; the MQTT topic in list
  form, where each of the topic levels are an item. This allows us to
  pattern match on topic filters with wildcards.

  The payload should be a term; at this point the message will have
  been run through a JSON decoder. If the JSON decode should fail the
  optional `handle_error/1` callback would have been triggered
  instead.
  """
  @callback handle_message(topic_levels, payload) :: any()

  @doc """
  Handle errors produced by Jackalope that should be reacted to

  During the connection life-cycle various errors can occur, and while
  Jackrabbit and Tortoise will try to correct the situation, some
  errors require user intervention. The optional `handle_error/1`
  callback can help inform the surrounding system of errors.

    @impl true
    def handle_error({:publish_error, work_order, :ttl_expired}) do
      Logger.error("Work order expired: \#{inspect(work_order)}")
    end

    def handle_error(_otherwise) do
      _ignore = nil
    end

  If this callback is implemented one should make sure to make a
  catch-all to prevent unhandled errors from crashing the handler.
  """
  @callback handle_error(reason) :: any()
            when reason:
                   {:payload_decode_error, {topic_levels, payload_string :: String.t()}}
                   | {:publish_error, {topic, payload, opts}, error_reason :: term}
                   | {:publish_error, jackalope_work_order :: term, :ttl_expired},
                 opts: Keyword.t()

  @optional_callbacks connection: 1,
                      subscription: 2,
                      handle_error: 1
end
