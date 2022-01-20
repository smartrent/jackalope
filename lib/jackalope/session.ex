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
  alias Jackalope.WorkList.Expiration

  require Logger

  @publish_options [:qos, :retain]
  @work_list_options [:ttl]
  # One hour
  @default_ttl_msecs 3_600_000

  defstruct connection_status: :offline,
            handler: nil,
            work_list: nil

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
  @spec publish(String.t(), any(), keyword) :: :ok | {:error, :invalid_qos | :invalid_ttl}
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
        expiration_fn: fn {_cmd, opts} -> Keyword.fetch!(opts, :expiration) end,
        update_expiration_fn: fn {cmd, opts}, expiration ->
          {cmd, Keyword.put(opts, :expiration, expiration)}
        end,
        max_size: max_work_list_size
      )
      |> work_list_mod.new()

    initial_state = %State{
      work_list: work_list,
      handler: handler
    }

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

        state = %State{
          state
          | work_list: WorkList.push(work_list, work_item)
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

    expiration = Expiration.expiration(ttl)

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

      {cmd, opts} ->
        expiration = Keyword.fetch!(opts, :expiration)

        if expired?(expiration) do
          # drop the message, it is outside of the time to live
          if function_exported?(state.handler, :handle_error, 1) do
            reason = {:publish_error, cmd, :ttl_expired}
            state.handler.handle_error(reason)
          end

          {:noreply, state, {:continue, :consume_work_list}}
        else
          case execute_work(cmd) do
            :ok ->
              # fire and forget work; Publish with QoS=0 is among the work
              # that doesn't produce references
              {:noreply, %State{state | work_list: WorkList.pop(work_list)},
               {:continue, :consume_work_list}}

            {:ok, ref} ->
              state = %State{
                state
                | work_list: WorkList.pending(work_list, ref)
              }

              {:noreply, state, {:continue, :consume_work_list}}

            {:error, reason} ->
              Logger.warn("[Jackalope] Temporarily failed to execute #{inspect(cmd)}: #{reason}")
              {:noreply, state}
          end
        end
    end
  end

  ### PRIVATE HELPERS --------------------------------------------------

  defp execute_work({:publish, topic, payload, opts}) do
    TortoiseClient.publish(topic, payload, opts)
  end

  defp expired?(expiration), do: Expiration.after?(Expiration.expiration(0), expiration)
end
