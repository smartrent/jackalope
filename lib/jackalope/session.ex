defmodule Jackalope.Session do
  @moduledoc false

  # MQTT session logic

  # The Jackalope module will serve as a message box, tracking the
  # status of the messages currently handled by Tortoise. This part of
  # the application is not supervised in the same supervision branch as
  # Tortoise, so we shouldn't drop important messages if Tortoise, or
  # any of its siblings should crash; and we should retry messages that
  # were not delivered for whatever reason.

  use GenServer

  require Logger

  alias __MODULE__, as: State
  alias Jackalope.{WorkList, TortoiseClient}

  defstruct connection_status: :offline,
            handler: nil,
            pending: %{},
            subscriptions: %{}

  def start_link(opts) do
    Logger.info("[Jackalope] Starting #{inspect(__MODULE__)}...")
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def whereis() do
    GenServer.whereis(__MODULE__)
  end

  ## MQTT-ing
  @doc false
  def subscribe(subscription, opts \\ [])

  def subscribe({topic_filter, subscribe_opts}, opts) do
    cmd = {:subscribe, topic_filter, subscribe_opts}

    cond do
      Keyword.get(subscribe_opts, :qos, 0) not in [0, 1] ->
        {:error, :unsupported_qos}

      _opts_looks_good! = true ->
        GenServer.cast(__MODULE__, {:cmd, cmd, opts})
    end
  end

  def subscribe(topic_filter, opts) do
    # lift the input to the correct format
    subscribe({topic_filter, []}, opts)
  end

  @doc false
  def unsubscribe(unsubscribe, opts \\ [])

  def unsubscribe({topic_filter, unsubscribe_opts}, opts) do
    cmd = {:unsubscribe, topic_filter, unsubscribe_opts}
    GenServer.cast(__MODULE__, {:cmd, cmd, opts})
  end

  def unsubscribe(topic_filter, opts) do
    # lift the input to the correct format
    unsubscribe({topic_filter, []}, opts)
  end

  @doc false
  def publish(topic_and_opts, payload, opts \\ [])

  def publish({topic_levels, publish_opts}, payload, opts) when is_list(topic_levels) do
    # normalize the topic list, should be a string
    topic = Enum.join(topic_levels, "/")
    publish({topic, publish_opts}, payload, opts)
  end

  def publish(topic, payload, opts) when not is_tuple(topic) do
    # normalize the topic to include the publish opts
    publish({topic, []}, payload, opts)
  end

  def publish({topic, publish_opts}, payload, opts) do
    cmd = {:publish, topic, payload, publish_opts}

    # Ensure the opts passed to the publish are allowed by AWS IoT
    cond do
      Keyword.get(publish_opts, :qos, 0) not in [0, 1] ->
        {:error, :unsupported_qos}

      Keyword.get(publish_opts, :retain, false) == true ->
        {:error, :retain_not_supported}

      _opts_looks_good! = true ->
        GenServer.cast(__MODULE__, {:cmd, cmd, opts})
    end
  end

  @doc false
  def status() do
    GenServer.call(__MODULE__, :status)
  end

  @doc false
  def reconnect() do
    GenServer.cast(__MODULE__, :reconnect)
  end

  @impl true
  def init(opts) do
    handler = Keyword.fetch!(opts, :handler)
    # Produce subscription commands for the initial subscriptions
    initial_topics = Keyword.get(opts, :initial_topics)

    for topic_filter <- List.wrap(initial_topics),
        do: push_work_order({{:subscribe, topic_filter, []}, []})

    initial_state = %State{handler: handler}

    {:ok, initial_state, {:continue, :consume_work_list}}
  end

  @impl true
  def handle_call(:status, _from, %State{} = state) do
    {:reply, Map.from_struct(state), state}
  end

  @impl true
  # Connection status changes
  def handle_info({:connection_status, :up}, state) do
    state = %State{state | connection_status: :online}
    {:noreply, state, {:continue, :consume_work_list}}
  end

  def handle_info({:connection_status, status}, state)
      when status in [:down, :terminating, :terminated] do
    state = %State{
      state
      | connection_status: :offline,
        # Reset the subscriptions and schedule a resubscribe to all
        # the current subscriptions for when we are back online. Note;
        # MQTT sessions should be able to handle this, but we do it
        # for good measure to ensure a consistent state of the world;
        # an upcoming Tortoise version will track this state in the
        # connection state, and the user can ask for it, so this
        # problem will go away in the future; also, as we add the
        # subscribe work-order at the front of the list, any
        # unsubscribe placed should come after this, making sure we
        # will not resubscribe to a topic we are no longer interested
        # in.
        subscriptions: %{}
    }

    for(
      {topic_filter, opts} <- state.subscriptions,
      do: push_work_order({{:subscribe, topic_filter, opts}, []})
    )

    {:noreply, state}
  end

  # Handle responses to user initiated commands; subscribe,
  # unsubscribe, publish...
  def handle_info(
        {:tortoise_result, ref, res},
        %State{pending: pending} = state
      ) do
    {work_order, pending} = Map.pop(pending, ref)
    state = %State{state | pending: pending}

    case res do
      _unknown_ref when is_nil(work_order) ->
        Logger.info("Received unknown ref from Tortoise: #{inspect(ref)}")
        {:noreply, state}

      :ok ->
        case work_order do
          {{:subscribe, topic, subscription_opts}, _opts} ->
            # Note that all subscriptions has to go through Jackalope;
            # for that reason we cannot use the "initial
            # subscriptions" in Tortoise, as Jackalope would not know
            # about them; the upcoming Tortoise will expose a function
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
        push_work_order(work_order)
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:cmd, cmd, opts}, state) do
    # Setup the options for the work order; so far we support time to
    # live, which allow us to specify the time a work order is allowed
    # to stay in the work list before it is deemed irrelevant
    opts =
      Keyword.update(opts, :ttl, :infinity, fn
        :infinity -> :infinity
        ttl when is_integer(ttl) -> System.monotonic_time(:millisecond) + ttl
      end)

    # Note that we don't really concern ourselves with the order of
    # the commands; the work_list is a list (and thus a stack) and when
    # we retry a message it will reenter the work list at the front,
    # and it could already have messages, etc.
    push_work_order({cmd, opts})
    {:noreply, state, {:continue, :consume_work_list}}
  end

  def handle_cast(:reconnect, state) do
    :ok = Jackalope.TortoiseClient.reconnect()
    # We will republish all the messages we got in pending; this
    # might result in messages being received twice, but this is
    # already an issue with QoS=1 messages; subscribes and
    # unsubscribes should be idempotent

    for {ref, work_order} when is_reference(ref) <- state.pending, do: push_work_order(work_order)

    {:noreply, %State{state | connection_status: :offline, pending: %{}}}
  end

  @impl true
  def handle_continue(:consume_work_list, %State{connection_status: :offline} = state) do
    # postpone consuming from the work list till we are online again!
    {:noreply, state}
  end

  # reductive case, consume work until the work list is empty
  def handle_continue(
        :consume_work_list,
        %State{
          connection_status: :online,
          pending: pending
        } = state
      ) do
    case pop_work_order() do
      nil ->
        {:noreply, state}

      {cmd, opts} = work_order ->
        ttl = Keyword.get(opts, :ttl, :infinity)

        if ttl > System.monotonic_time(:millisecond) do
          case execute_work(cmd) do
            :ok ->
              # fire and forget work; Publish with QoS=0 is among the work
              # that doesn't produce references
              {:noreply, state, {:continue, :consume_work_list}}

            {:ok, ref} ->
              {:noreply, %State{state | pending: Map.put_new(pending, ref, work_order)},
               {:continue, :consume_work_list}}

            {:error, :no_connection} ->
              # Put work order back on work list
              push_work_order(work_order)
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

  defp pop_work_order() do
    case WorkList.pop() do
      {:ok, work_order} -> work_order
      nil -> nil
    end
  end

  defp push_work_order(work_order) do
    :ok = WorkList.push(work_order)
  end

  # ### PRIVATE HELPERS --------------------------------------------------

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
