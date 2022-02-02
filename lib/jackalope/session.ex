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

  alias __MODULE__, as: State
  alias Jackalope.{TortoiseClient, WorkList}
  alias Jackalope.Item
  alias Jackalope.Timestamp

  require Logger

  @typedoc false
  @type publish_option() :: {:qos, 0..2} | {:ttl, non_neg_integer()}

  # One hour
  @default_ttl_msecs 3_600_000

  # Sync each minute
  @sync_period 60_000

  defstruct connection_status: :offline,
            handler: nil,
            work_list: nil,
            time_offset: 0

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    Logger.info("[Jackalope] Starting #{inspect(__MODULE__)} with #{inspect(opts)}")
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec report_tortoise_result(reference(), any) :: :ok
  def report_tortoise_result(reference, result) do
    GenServer.cast(__MODULE__, {:report_tortoise_result, reference, result})
  end

  @spec report_connection_status(:up | :down | :terminating | :terminated) :: :ok
  def report_connection_status(status) do
    GenServer.cast(__MODULE__, {:report_connection_status, status})
  end

  ## MQTT-ing

  @doc false
  @spec publish(String.t(), binary(), [publish_option()]) ::
          :ok | {:error, :invalid_qos | :invalid_ttl}
  def publish(topic, payload, opts \\ []) when is_binary(topic) do
    ttl = Keyword.get(opts, :ttl, @default_ttl_msecs)

    # Aside from TTL, the only supported option is :qos for now
    publish_opts = Keyword.take(opts, [:qos])

    cond do
      Keyword.get(publish_opts, :qos, 0) not in 0..2 ->
        {:error, :invalid_qos}

      not (is_integer(ttl) and ttl > 0) ->
        {:error, :invalid_ttl}

      _opts_look_good! = true ->
        GenServer.cast(__MODULE__, {:publish, topic, payload, ttl, publish_opts})
    end
  end

  @doc false
  @spec reconnect() :: :ok
  def reconnect() do
    GenServer.cast(__MODULE__, :reconnect)
  end

  @impl GenServer
  def init(opts) do
    handler = Keyword.fetch!(opts, :handler)
    max_work_list_size = Keyword.fetch!(opts, :max_work_list_size)
    work_list_mod = Keyword.fetch!(opts, :work_list_mod)

    work_list =
      Keyword.merge(opts,
        max_size: max_work_list_size
      )
      |> work_list_mod.new()

    latest_jack_time = WorkList.latest_timestamp(work_list)
    offset = Timestamp.calculate_offset(latest_jack_time)

    initial_state = %State{
      work_list: work_list,
      handler: handler,
      time_offset: offset
    }

    # Schedule a sync immediately since it could be that recovery or first time
    # initialization caused the in-memory state to be diverge from what was
    # persisted
    send(self(), :tick)

    {:ok, initial_state, {:continue, :consume_work_list}}
  end

  @impl GenServer
  # Connection status changes
  def handle_cast({:report_connection_status, :up}, state) do
    state = %State{state | connection_status: :online}
    {:noreply, state, {:continue, :consume_work_list}}
  end

  def handle_cast({:report_connection_status, status}, state)
      when status in [:down, :terminating, :terminated] do
    state = %State{state | connection_status: :offline}
    {:noreply, state}
  end

  # Handle responses to user initiated publish...
  def handle_cast(
        {:report_tortoise_result, ref, res},
        %State{work_list: work_list} = state
      ) do
    {updated_work_list, work_item} = WorkList.done(work_list, ref)
    state = %State{state | work_list: updated_work_list}

    case res do
      _unknown_ref when is_nil(work_item) ->
        Logger.info("Received unknown ref from Tortoise311: #{inspect(ref)}")
        {:noreply, state}

      :ok ->
        {:noreply, state}

      {:error, reason} ->
        Logger.warn("Retrying message, failed with reason: #{inspect(reason)}")

        now = jackalope_now(state)
        state = %State{state | work_list: WorkList.push(work_list, work_item, now)}

        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_cast({:publish, topic, payload, ttl, opts}, %State{} = state) do
    # Convert the TTL to an expiration time and then add the item to the work list
    now = jackalope_now(state)
    expiration = Timestamp.ttl_to_expiration(now, ttl)

    item = %Item{expiration: expiration, topic: topic, payload: payload, options: opts}

    state = %State{state | work_list: WorkList.push(state.work_list, item, now)}
    {:noreply, state, {:continue, :consume_work_list}}
  end

  def handle_cast(:reconnect, state) do
    :ok = Jackalope.TortoiseClient.reconnect()

    state = %State{
      state
      | connection_status: :offline,
        # We will republish all the messages we got in pending; this
        # might result in messages being received twice, but this is
        work_list: WorkList.reset_pending(state.work_list)
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
          work_list: work_list
        } = state
      ) do
    case WorkList.peek(work_list) do
      nil ->
        {:noreply, state}

      item ->
        now = jackalope_now(state)

        if now > item.expiration do
          # drop the message, it is outside of the time to live
          if function_exported?(state.handler, :handle_error, 1) do
            reason = {:publish_error, item, :ttl_expired}
            state.handler.handle_error(reason)
          end

          {:noreply, state, {:continue, :consume_work_list}}
        else
          case TortoiseClient.publish(item) do
            :ok ->
              # fire and forget work; Publish with QoS=0 is among the work
              # that doesn't produce references
              {:noreply, %State{state | work_list: WorkList.pop(work_list)},
               {:continue, :consume_work_list}}

            {:ok, ref} ->
              state = %State{
                state
                | work_list: WorkList.pending(work_list, ref, now)
              }

              {:noreply, state, {:continue, :consume_work_list}}

            {:error, reason} ->
              Logger.warn("[Jackalope] Temporarily failed to execute #{inspect(item)}: #{reason}")
              {:noreply, state}
          end
        end
    end
  end

  @impl GenServer
  def handle_info(:tick, state) do
    now = jackalope_now(state)
    new_work_list = WorkList.sync(state.work_list, now)

    Process.send_after(self(), :tick, @sync_period)

    {:noreply, %{state | work_list: new_work_list}}
  end

  def handle_info(_other, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    now = jackalope_now(state)
    new_work_list = WorkList.sync(state.work_list, now)
    %{state | work_list: new_work_list}
  end

  ### PRIVATE HELPERS --------------------------------------------------

  defp jackalope_now(state) do
    Timestamp.now(state.time_offset)
  end
end
