defmodule Jackalope.Session do
  @moduledoc false

  # MQTT session logic

  # The Jackalope module will serve as a message box, tracking the
  # status of the messages currently handled by Tortoise311. This part of
  # the application is not supervised in the same supervision branch as
  # Tortoise311, so we shouldn't drop important messages if Tortoise311, or
  # any of its siblings should crash; and we should retry messages that
  # was not delivered for whatever reason.

  use GenServer

  require Logger

  alias __MODULE__, as: State
  alias Jackalope.{TortoiseClient, WorkList}

  @publish_options [:qos, :retain]
  @subscribe_options [:qos]
  @work_list_options [:ttl]
  # One hour
  @default_ttl_msecs 3_600_000

  defstruct connection_status: :offline,
            handler: nil,
            work_list: nil,
            pending: %{},
            subscriptions: %{}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    Logger.info("[Jackalope] Starting #{inspect(__MODULE__)} with #{inspect(opts)}")
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec whereis() :: pid | nil
  def whereis() do
    GenServer.whereis(__MODULE__)
  end

  ## MQTT-ing
  @doc false
  def subscribe(topic_filter, opts) when is_binary(topic_filter) do
    subscribe_options = Keyword.take(opts, @subscribe_options)
    work_list_options = Keyword.take(opts, @work_list_options)
    ttl = Keyword.get(work_list_options, :ttl, @default_ttl_msecs)
    cmd = {:subscribe, topic_filter, subscribe_options}

    cond do
      Keyword.get(subscribe_options, :qos, 0) not in 0..2 ->
        {:error, :invalid_qos}

      not (is_integer(ttl) and ttl > 0) ->
        {:error, :invalid_ttl}

      _opts_looks_good! = true ->
        GenServer.cast(__MODULE__, {:cmd, cmd, work_list_options})
    end
  end

  @doc false
  def unsubscribe(topic_filter, opts) do
    unsubscribe_options = Keyword.take(opts, @subscribe_options)
    work_list_options = Keyword.take(opts, @work_list_options)
    ttl = Keyword.get(work_list_options, :ttl, @default_ttl_msecs)
    cmd = {:unsubscribe, topic_filter, unsubscribe_options}

    cond do
      Keyword.get(unsubscribe_options, :qos, 0) not in 0..2 ->
        {:error, :invalid_qos}

      not (is_integer(ttl) and ttl > 0) ->
        {:error, :invalid_ttl}

      _opts_looks_good! = true ->
        GenServer.cast(__MODULE__, {:cmd, cmd, work_list_options})
    end
  end

  @doc false
  def publish(topic, payload, opts) when is_binary(topic) do
    publish_opts = Keyword.take(opts, @publish_options)
    work_list_options = Keyword.take(opts, @work_list_options)
    ttl = Keyword.get(work_list_options, :ttl, @default_ttl_msecs)
    cmd = {:publish, topic, payload, publish_opts}

    cond do
      Keyword.get(publish_opts, :qos, 0) not in 0..2 ->
        {:error, :invalid_qos}

      not (is_integer(ttl) and ttl > 0) ->
        {:error, :invalid_ttl}

      _opts_looks_good! = true ->
        GenServer.cast(__MODULE__, {:cmd, cmd, work_list_options})
    end
  end

  @doc false
  def status() do
    GenServer.call(__MODULE__, :status)
  end

  @doc false
  @spec reconnect() :: :ok
  def reconnect() do
    GenServer.cast(__MODULE__, :reconnect)
  end

  @impl GenServer
  def init(opts) do
    handler = Keyword.fetch!(opts, :handler)
    # Produce subscription commands for the initial subscriptions
    initial_topics = Keyword.get(opts, :initial_topics)
    max_work_list_size = Keyword.fetch!(opts, :max_work_list_size)
    default_expiration = WorkList.expiration(@default_ttl_msecs)

    initial_items =
      for topic_filter <- List.wrap(initial_topics),
          do: {{:subscribe, topic_filter, []}, [expiration: default_expiration]}

    work_list = WorkList.new(initial_items, max_work_list_size)

    initial_state = %State{
      work_list: work_list,
      handler: handler
    }

    {:ok, initial_state, {:continue, :consume_work_list}}
  end

  @impl GenServer
  def handle_call(:status, _from, %State{} = state) do
    {:reply, Map.from_struct(state), state}
  end

  @impl GenServer
  # Connection status changes
  def handle_info({:connection_status, :up}, state) do
    state = %State{state | connection_status: :online}
    {:noreply, state, {:continue, :consume_work_list}}
  end

  def handle_info({:connection_status, status}, state)
      when status in [:down, :terminating, :terminated] do
    default_expiration = WorkList.expiration(@default_ttl_msecs)

    subscription_items =
      for(
        {topic_filter, opts} <- state.subscriptions,
        do: {{:subscribe, topic_filter, opts}, [expiration: default_expiration]}
      )

    state = %State{
      state
      | connection_status: :offline,
        # Reset the subscriptions and schedule a resubscribe to all
        # the current subscriptions for when we are back online. Note;
        # MQTT sessions should be able to handle this, but we do it
        # for good measure to ensure a consistent state of the world;
        # an upcoming Tortoise311 version will track this state in the
        # connection state, and the user can ask for it, so this
        # problem will go away in the future; also, as we add the
        # subscribe work-order at the front of the list, any
        # unsubscribe placed should come after this, making sure we
        # will not resubscribe to a topic we are no longer interested
        # in.
        subscriptions: %{},
        work_list: WorkList.prepend(state.work_list, subscription_items)
    }

    {:noreply, state}
  end

  # Handle responses to user initiated commands; subscribe,
  # unsubscribe, publish...
  def handle_info(
        {:tortoise_result, ref, res},
        %State{pending: pending} = state
      ) do
    {work_item, pending} = Map.pop(pending, ref)
    state = %State{state | pending: pending}

    case res do
      _unknown_ref when is_nil(work_item) ->
        Logger.info("Received unknown ref from Tortoise311: #{inspect(ref)}")
        {:noreply, state}

      :ok ->
        case work_item do
          {{:subscribe, topic, subscription_opts}, _opts} ->
            # Note that all subscriptions has to go through Jackalope;
            # for that reason we cannot use the "initial
            # subscriptions" in Tortoise311, as Jackalope would not know
            # about them; the upcoming Tortoise311 will expose a function
            # for the subscriptions state!
            state = %State{
              state
              | subscriptions: Map.put(state.subscriptions, topic, subscription_opts)
            }

            {:noreply, state}

          {{:unsubscribe, topic, _}, _opts} ->
            state = %State{
              state
              | subscriptions: Map.delete(state.subscriptions, topic)
            }

            {:noreply, state}

          _otherwise ->
            {:noreply, state}
        end

      {:error, reason} ->
        Logger.warn("Retrying message, failed with reason: #{inspect(reason)}")

        state = %State{
          state
          | work_list: WorkList.push(state.work_list, work_item)
        }

        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_cast({:cmd, cmd, opts}, %State{work_list: work_list} = state) do
    # Setup the options for the work order; so far we support time to
    # live, which allow us to specify the time a work order is allowed
    # to stay in the work list before it is deemed irrelevant
    ttl = Keyword.get(opts, :ttl, @default_ttl_msecs)

    expiration = WorkList.expiration(ttl)

    # Note that we don't really concern ourselves with the order of
    # the commands; the work_list is a list (and thus a stack) and when
    # we retry a message it will reenter the work list at the front,
    # and it could already have messages, etc.
    work_opts = [expiration: expiration]
    work_item = {cmd, work_opts}
    state = %State{state | work_list: WorkList.push(work_list, work_item)}
    {:noreply, state, {:continue, :consume_work_list}}
  end

  def handle_cast(:reconnect, state) do
    :ok = Jackalope.TortoiseClient.reconnect()

    pending_work_items =
      for(
        {ref, work_order} when is_reference(ref) <- state.pending,
        do: work_order
      )

    state = %State{
      state
      | connection_status: :offline,
        # We will republish all the messages we got in pending; this
        # might result in messages being received twice, but this is
        # already an issue with QoS=1 messages; subscribes and
        # unsubscribes should be idempotent
        pending: %{},
        work_list: WorkList.prepend(state.work_list, pending_work_items)
    }

    {:noreply, state}
  end

  @impl GenServer
  def handle_continue(:consume_work_list, %State{connection_status: :offline} = state) do
    # postpone consuming from the work list till we are online again!
    {:noreply, state}
  end

  # reductive case, consume work until the work list is empty
  def handle_continue(
        :consume_work_list,
        %State{
          connection_status: :online,
          work_list: work_list,
          pending: pending
        } = state
      ) do
    if WorkList.empty?(work_list) do
      {:noreply, state}
    else
      {cmd, opts} = work_item = WorkList.peek(work_list)
      expiration = Keyword.fetch!(opts, :expiration)

      if expiration > WorkList.expiration(0) do
        case execute_work(cmd) do
          :ok ->
            # fire and forget work; Publish with QoS=0 is among the work
            # that doesn't produce references
            {:noreply, %State{state | work_list: WorkList.pop(work_list)},
             {:continue, :consume_work_list}}

          {:ok, ref} ->
            state = %State{
              state
              | work_list: WorkList.pop(work_list),
                pending: Map.put_new(pending, ref, work_item)
            }

            {:noreply, state, {:continue, :consume_work_list}}

          # TODO - {:error, reason}
          {:error, :no_connection} ->
            {:noreply, state}
        end
      else
        # drop the message, it is outside of the time to live
        if function_exported?(state.handler, :handle_error, 1) do
          reason = {:publish_error, cmd, :ttl_expired}
          apply(state.handler, :handle_error, [reason])
        end

        {:noreply, state, {:continue, :consume_work_list}}
      end
    end
  end

  ### PRIVATE HELPERS --------------------------------------------------

  defp execute_work({:publish, topic, payload, opts}) do
    TortoiseClient.publish(topic, payload, opts)
  end

  defp execute_work({:subscribe, topic_filter, opts}) do
    TortoiseClient.subscribe(topic_filter, opts)
  end

  defp execute_work({:unsubscribe, topic_filter, opts}) do
    # the unsubscribe does not take any options, but it might do in
    # the future, keeping it to make future upgrades easier
    TortoiseClient.unsubscribe(topic_filter, opts)
  end
end
