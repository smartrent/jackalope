defmodule Hare do
  @moduledoc """
  MQTT application logic

  The Hare module will serve as a message box, tracking the status of
  the messages currently handled by Tortoise. This part of the
  application is not supervised in the same supervision branch as
  Tortoise, so we shouldn't drop important messages if Tortoise, or
  any of its siblings should crash; and we should retry messages that
  was not delivered for whatever reason.
  """

  use GenServer

  @behaviour Hare.AppHandler
  require Logger

  alias __MODULE__, as: State
  alias Hare.TortoiseClient

  @qos 1

  defstruct connection_status: :offline,
            work_list: [],
            pending: %{},
            subscriptions: %{}

  def start_link(_) do
    Logger.info("[Hare] Starting #{inspect(__MODULE__)}...")
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def whereis() do
    GenServer.whereis(__MODULE__)
  end

  ## Configuration support

  @spec client_id() :: String.t()
  def client_id(), do: Application.get_env(:hare, :client_id)

  @spec connection_options() :: Keyword.t()
  def connection_options() do
    [
      server: {
        Tortoise.Transport.Tcp,
        host: mqtt_host(), port: mqtt_port()
      },
      will: %Tortoise.Package.Publish{
        topic: "#{client_id()}/message",
        payload: "last will",
        dup: false,
        qos: @qos,
        retain: false
      },
      # Subcriptions are set after all devices inclusions are recovered
      backoff: [min_interval: 100, max_interval: 30_000]
    ]
  end

  ## MQTT-ing
  @doc """
  Subscribe to a topic filter on the MQTT server
  """
  def subscribe(subscription, opts \\ [])

  def subscribe({topic_filter, subscribe_opts}, opts) do
    cmd = {:subscribe, topic_filter, subscribe_opts}
    GenServer.cast(__MODULE__, {:cmd, cmd, opts})
  end

  def subscribe(topic_filter, opts) do
    # lift the input to the correct format
    subscribe({topic_filter, []}, opts)
  end

  @doc """
  Unsubscribe from a topic filter on the MQTT server
  """
  def unsubscribe(ubsubscribe, opts \\ [])

  def unsubscribe({topic_filter, unsubscribe_opts}, opts) do
    cmd = {:unsubscribe, topic_filter, unsubscribe_opts}
    GenServer.cast(__MODULE__, {:cmd, cmd, opts})
  end

  def unsubscribe(topic_filter, opts) do
    # lift the input to the correct format
    unsubscribe({topic_filter, []}, opts)
  end

  @doc """
  Publish an MQTT message
  """
  def publish(topic_and_opts, payload, opts \\ [])

  def publish({topic, publish_opts}, payload, opts) when is_list(topic) do
    # normalize the topic list, should be a string
    topic = Enum.join(topic, "/")
    publish({topic, publish_opts}, payload, opts)
  end

  def publish(topic, payload, opts) when not is_tuple(topic) do
    # normalize the topic to include the publish opts
    publish({topic, []}, payload, opts)
  end

  def publish({topic, publish_opts}, payload, opts) do
    cmd = {:publish, topic, payload, publish_opts}
    GenServer.cast(__MODULE__, {:cmd, cmd, opts})
  end

  ## Testing
  def status() do
    GenServer.call(__MODULE__, :status)
  end

  def reconnect() do
    GenServer.cast(__MODULE__, :reconnect)
  end

  ### AppHandler callbacks

  @impl true
  def tortoise_result(client_id, reference, result) do
    Logger.info(
      "[Hare] Tortoise result for client #{inspect(client_id)} referenced by #{inspect(reference)} is #{
        inspect(result)
      }"
    )

    GenServer.cast(__MODULE__, {:tortoise_result, client_id, reference, result})
  end

  @impl true
  def message_received(topic, payload) do
    Logger.info(
      "[Hare] Tortoise received message with topic #{inspect(topic)} and payload #{
        inspect(payload)
      }"
    )

    :ok
  end

  @impl true
  def invalid_payload(topic, payload) do
    Logger.info(
      "[Hare] Tortoise received an invalid message with topic #{inspect(topic)} and payload #{
        inspect(payload)
      }"
    )

    :ok
  end

  ### GenServer callbacks

  @impl true
  def init(_) do
    # Produce subscription commands for the initial subscriptions
    work_list =
      for topic_filter <- initial_topics(),
          do: {{:subscribe, topic_filter, []}, []}

    {:ok, %State{work_list: work_list}, {:continue, :consume_work_list}}
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
        # ubsubscribe placed should come after this, making sure we
        # will not resubscribe to a topic we are no longer interested
        # in.
        subscriptions: %{},
        work_list:
          Enum.concat([
            for(
              {topic_filter, opts} <- state.subscriptions,
              do: {{:subscribe, topic_filter, opts}, []}
            ),
            state.work_list
          ])
    }

    {:noreply, state}
  end

  @impl true
  # Handle responses to user initiated commands; subscribe,
  # unsubscribe, publish...
  def handle_cast(
        {:tortoise_result, _client_id, ref, res},
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
            # Note that all subscriptions has to go through Hare; for
            # that reason we cannot use the "initial subscriptions" in
            # Tortoise, as Hare would not know about them; the
            # upcoming Tortoise will expose a function for the
            # subscriptions state!
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
        state = %State{state | work_list: [work_order | state.work_list]}
        {:noreply, state}
    end
  end

  def handle_cast({:cmd, cmd, opts}, %State{work_list: work_list} = state) do
    # Setup the options for the work order; so far we support time to
    # live, which allow us to specify the time a work order is allowed
    # to stay in the work list before it is deemed irrelevant
    opts =
      Keyword.update(opts, :ttl, :infinity, fn
        :infinity -> :infinity
        ttl when is_integer(ttl) -> System.monotonic_time(:millisecond) + ttl
      end)

    # Note that we don't really concern ourselves with the order of
    # the commands; the worklist is a list (and thus a stack) and when
    # we retry a message it will reenter the work list at the front,
    # and it could already have messages, etc.
    work_list = [{cmd, opts} | work_list]
    state = %State{state | work_list: work_list}
    {:noreply, state, {:continue, :consume_work_list}}
  end

  def handle_cast(:reconnect, state) do
    :ok = Hare.TortoiseClient.reconnect()

    state = %State{
      state
      | connection_status: :offline,
        # We will republish all the messages we got in pending; this
        # might result in messages being received twice, but this is
        # already an issue with QoS=1 messages; subscribes and
        # unsubscribes should be idempotent
        pending: %{},
        work_list:
          Enum.concat([
            for(
              {ref, work_order} when is_reference(ref) <- state.pending,
              do: work_order
            ),
            state.work_list
          ])
    }

    {:noreply, state}
  end

  @impl true
  def handle_continue(:consume_work_list, %State{connection_status: :offline} = state) do
    # postpone consuming from the work list till we are online again!
    {:noreply, state}
  end

  def handle_continue(:consume_work_list, %State{work_list: []} = state) do
    # base-case; we are done consuming and will idle until more work
    # is produced
    {:noreply, state}
  end

  # reductive case, consume work untill the work list is empty
  def handle_continue(
        :consume_work_list,
        %State{
          connection_status: :online,
          work_list: [{cmd, opts} = work_order | remaining],
          pending: pending
        } = state
      ) do
    state = %State{state | work_list: remaining}
    ttl = Keyword.get(opts, :ttl, :infinity)

    if ttl > System.monotonic_time(:millisecond) do
      case execute_work(cmd) do
        :ok ->
          # fire and forget work; Publish with QoS=0 is among the work
          # that doesn't produce references
          {:noreply, state, {:continue, :consume_work_list}}

        {:ok, ref} ->
          state = %State{state | pending: Map.put_new(pending, ref, work_order)}
          {:noreply, state, {:continue, :consume_work_list}}
      end
    else
      # drop the message, it is outside of the time to live
      Logger.warn("TTL Expired, Message dropped: #{inspect(cmd)}")
      {:noreply, state, {:continue, :consume_work_list}}
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

  defp initial_topics() do
    Application.get_env(:hare, :base_topics, [])
  end

  defp mqtt_host(), do: Application.get_env(:hare, :mqtt_host)
  defp mqtt_port(), do: Application.get_env(:hare, :mqtt_port)
end
