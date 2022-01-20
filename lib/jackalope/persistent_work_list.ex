defmodule Jackalope.PersistentWorkList do
  @moduledoc """
  A genserver wrapper for CubQ which we leverage to store and restore worklist tasks during disconnections
  """
  use GenServer

  alias Jackalope.WorkList.Expiration

  require Logger

  @default_max_size 100

  @tick_delay 10 * 60 * 1_000

  defmodule State do
    @moduledoc false
    defstruct db: nil,
              queue: nil,
              max_size: nil,
              expiration_fn: nil,
              update_expiration_fn: nil
  end

  @doc "Create a new work list"
  @spec new(Keyword.t()) :: pid()
  def new(opts) do
    Logger.info("[Jackalope] Starting #{__MODULE__} with #{inspect(opts)}")
    {:ok, pid} = GenServer.start_link(__MODULE__, opts)
    pid
  end

  @impl GenServer
  def init(opts) do
    {db, queue} = start_queue(opts)
    send(self(), :tick)

    {:ok,
     %State{
       db: db,
       queue: queue,
       max_size: Keyword.get(opts, :max_size, @default_max_size),
       expiration_fn: Keyword.fetch!(opts, :expiration_fn),
       update_expiration_fn: Keyword.fetch!(opts, :update_expiration_fn)
     }, {:continue, :recover}}
  end

  @impl GenServer
  def handle_continue(:recover, state) do
    recover(state, state.expiration_fn, state.update_expiration_fn)
    CubDB.put(state.db, :pending, %{})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    :ok = record_time_now(state)
    Process.send_after(self(), :tick, @tick_delay)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:count, _from, state) do
    {:reply, queue_size(state), state}
  end

  def handle_call(:count_pending, _from, state) do
    {:reply, Enum.count(get_pending(state)), state}
  end

  def handle_call(:peek, _from, state) do
    peek =
      case CubQ.peek_last(state.queue) do
        nil -> nil
        {:ok, item} -> item
      end

    {:reply, peek, state}
  end

  def handle_call({:done, ref}, _from, state) do
    pending = get_pending(state)
    {item, updated_pending} = Map.pop(pending, ref)
    :ok = update_pending(state, updated_pending)
    {:reply, item, state}
  end

  def handle_call(:remove_all, _from, state) do
    :ok = CubQ.delete_all(state.queue)
    :ok = update_pending(state, %{})
    {:reply, :ok, state}
  end

  def handle_call(:pop, _from, state) do
    {:ok, _item} = CubQ.pop(state.queue)
    {:reply, :ok, state}
  end

  def handle_call({:push, item}, _from, state) do
    :ok = CubQ.push(state.queue, item)
    {:reply, :ok, bound_work_items(state)}
  end

  def handle_call({:pending, ref}, _from, state) do
    {:ok, item} = CubQ.pop(state.queue)

    add_pending(state, item, ref)

    {:reply, :ok, state}
  end

  def handle_call(:reset_pending, _from, state) do
    :ok =
      Enum.each(get_pending(state), fn {_ref, value} -> :ok = CubQ.push(state.queue, value) end)

    :ok = update_pending(state, %{})

    {:reply, :ok, bound_work_items(state)}
  end

  @impl GenServer
  def terminate(_reason, state) do
    record_time_now(state)
  end

  defp start_queue(opts) do
    data_dir = Keyword.get(opts, :data_dir, "/data/jackalope")

    cubdb_opts = [data_dir: data_dir, name: :work_list, auto_compact: true]

    {:ok, db} =
      case CubDB.start_link(cubdb_opts) do
        {:error, reason} ->
          Logger.warn("[Jackalope] Corrupted DB : #{inspect(reason)}. Erasing it.")
          _ = File.rmdir(data_dir)
          CubDB.start_link(cubdb_opts)

        success ->
          success
      end

    CubDB.set_auto_file_sync(db, true)

    queue =
      case CubQ.start_link(db: db, queue: :items) do
        {:ok, pid} ->
          pid

        {:error, {:already_started, pid}} ->
          pid

        other ->
          Logger.warn("[Jackalope] Corrupted queue : #{inspect(other)}. Erasing DB.")
          _ = File.rmdir(data_dir)
          raise "Corrupted work list queue"
      end

    {db, queue}
  end

  defp add_pending(state, item, ref) do
    updated_pending = get_pending(state) |> Map.put(ref, item) |> bound_pending_items(state)

    :ok = update_pending(state, updated_pending)
  end

  defp bound_work_items(state) do
    max = state.max_size

    if queue_size(state) > max do
      :ok = remove_expired_work_items(state)
      excess = queue_size(state) - max

      _ = if excess >= 0, do: remove_excess(excess, state)
    end

    state
  end

  defp remove_excess(excess, state) do
    Enum.each(
      1..excess,
      fn _i ->
        {:ok, item_removed} = CubQ.dequeue(state.queue)

        Logger.info(
          "[Jackalope] WorkList - The worklist still exceeds max size. #{inspect(item_removed)} was removed from the queue."
        )
      end
    )
  end

  defp remove_expired_work_items(state) do
    Enum.each(
      1..queue_size(state),
      fn _i ->
        # remove from beginning
        {:ok, item} = CubQ.dequeue(state.queue)

        if Expiration.unexpired?(item, state.expiration_fn) do
          # same as push (insert at end)
          :ok = CubQ.enqueue(state.queue, item)
        else
          Logger.debug(
            "[Jackalope] #{inspect(item)} removed from the queue due to expiration. Size is #{queue_size(state)}"
          )
        end
      end
    )
  end

  # Trim pending as needed to accommodate an additional pending item
  defp bound_pending_items(pending, state) do
    if map_size(pending) > state.max_size do
      # Trim expired pending requests
      kept_pairs =
        Enum.reduce(
          pending,
          [],
          fn {ref, item}, acc ->
            if Expiration.unexpired?(item, state.expiration_fn) do
              [{ref, item} | acc]
            else
              acc
            end
          end
        )

      # If still over maximum, remove the oldest pending request (expiration is smallest)
      if length(kept_pairs) > state.max_size do
        [{ref, item} | newer_pairs] =
          Enum.sort(kept_pairs, fn {_, item1}, {_, item2} ->
            Expiration.after?(state.expiration_fn.(item2), state.expiration_fn.(item1))
          end)

        Logger.info(
          "[Jackalope] Maximum number of unexpired pending requests reached. Dropping #{inspect(item)}:#{inspect(ref)}."
        )

        newer_pairs
      else
        kept_pairs
      end
      |> Enum.into(%{})
    else
      pending
    end
  end

  defp get_pending(state), do: CubDB.get(state.db, :pending) || %{}

  defp update_pending(state, updated_pending),
    do: :ok = CubDB.put(state.db, :pending, updated_pending)

  defp queue_size(state), do: CubDB.size(state.db) - 2

  defp record_time_now(state) do
    :ok = CubDB.put(state.db, :latest_time, Expiration.now())
  end

  # After restart, recover and rebase the persisted items from the previous to the new system monotonic time.
  # Assumes that restart occurred shortly after shutdown, or this is the first time the work list was created.
  defp recover(state, expiration_fn, update_expiration_fn) do
    # latest_time is nil if this is a never-persisted work list
    latest_time = CubDB.get(state.db, :latest_time)
    now = Expiration.now()
    # Rebase the expiration of queued (waiting) items
    items_count = queue_size(state)

    if items_count > 0 do
      Enum.each(
        1..items_count,
        fn _i ->
          {:ok, waiting_item} = CubQ.dequeue(state.queue)

          expiration =
            Expiration.rebase_expiration(expiration_fn.(waiting_item), latest_time, now)

          :ok = CubQ.enqueue(state.queue, update_expiration_fn.(waiting_item, expiration))
        end
      )
    end

    # Convert pending items into waiting items with rebased expirations
    Enum.each(
      get_pending(state),
      fn {_ref, pending_item} ->
        expiration = Expiration.rebase_expiration(expiration_fn.(pending_item), latest_time, now)
        :ok = CubQ.enqueue(state.queue, update_expiration_fn.(pending_item, expiration))
      end
    )
  end
end

defimpl Jackalope.WorkList, for: PID do
  @impl Jackalope.WorkList
  def peek(work_list) do
    GenServer.call(work_list, :peek)
  end

  @impl Jackalope.WorkList
  def push(work_list, item) do
    :ok = GenServer.call(work_list, {:push, item})
    work_list
  end

  @impl Jackalope.WorkList
  def pop(work_list) do
    :ok = GenServer.call(work_list, :pop)
    work_list
  end

  @impl Jackalope.WorkList
  def pending(work_list, ref) do
    :ok = GenServer.call(work_list, {:pending, ref})
    work_list
  end

  @impl Jackalope.WorkList
  def reset_pending(work_list) do
    :ok = GenServer.call(work_list, :reset_pending)
    work_list
  end

  @impl Jackalope.WorkList
  def done(work_list, ref) do
    item = GenServer.call(work_list, {:done, ref})
    {work_list, item}
  end

  @impl Jackalope.WorkList
  def count(work_list) do
    GenServer.call(work_list, :count)
  end

  @impl Jackalope.WorkList
  def count_pending(work_list) do
    GenServer.call(work_list, :count_pending)
  end

  @impl Jackalope.WorkList
  def empty?(work_list), do: peek(work_list) == nil

  @impl Jackalope.WorkList
  def remove_all(work_list) do
    :ok = GenServer.call(work_list, :remove_all)
    work_list
  end
end
