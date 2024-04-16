defmodule Jackalope.Handler do
  @moduledoc """
  Behaviour defining callbacks triggered during the MQTT life-cycle

  The jackalope handler is stateless, so if state is needed one could
  route the messages to stateful processes, and inform the system
  about connection and subscription state.

  Most of the callbacks are optional.
  """

  @type topic :: Tortoise311.topic()
  @type topic_filter :: Tortoise311.topic_filter()
  @type topic_levels :: [String.t()]
  @type payload :: term()
  @type last_will :: [topic: topic, payload: payload, qos: non_neg_integer()]
  @type socket :: any()
  @type server :: atom()

  @doc """
  Called when the MQTT connection changes status

  This can be used to inform other parts of the system about the state
  of the connection; possible values are `:up` and `:down`, where up
  means that the MQTT client has a connection to the broker; down
  means that the connection has been dropped.
  """
  @callback connection(status :: :up | :down) :: any()

  @doc """
  Called when connected to an MQTT server

  This can be used to inform other parts of the system about the type
  of connection and the connected socket.
  """
  @callback connected(server :: server(), socket()) :: any()

  @doc """
  Produces the last will message for the current connection, or nil if the last will in the connection options is to be used
  Example: [topic: hub_serial_number/message", payload: %{code: "going_down", msg: "Last will message"}, qos: 1]
  """
  @callback last_will() :: last_will | nil

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
  """
  @callback handle_message(topic_levels, payload) :: any()

  @doc """
  Handle errors produced by Jackalope that should be reacted to

  During the connection life-cycle various errors can occur, and while
  Jackrabbit and Tortoise311 will try to correct the situation, some
  errors require user intervention. The optional `handle_error/1`
  callback can help inform the surrounding system of errors.

      @impl Jackalope.Handler
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
                   {:publish_error, {topic, payload, opts}, error_reason :: term}
                   | {:publish_error, jackalope_work_order :: term, :ttl_expired},
                 opts: Keyword.t()

  @optional_callbacks connection: 1,
                      subscription: 2,
                      handle_error: 1
end
