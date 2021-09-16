defmodule Jackalope.PersistentWorkList do
  @moduledoc """
  A genserver wrapper for CubQ which we leverage to store and restore worklist tasks during disconnections
  """
  use GenServer
  require Logger

  alias Jackalope.WorkList

  @behaviour WorkList

  @default_max_size 100
  @tick_delay 10 * 60 * 1_000

  defmodule State do
    @moduledoc false
    defstruct db: nil,
              queue: nil,
              queue_name: nil,
              max_work_list_size: nil,
              expiration_fn: nil
  end

  @doc "Starts the CubQ process"
  @spec start_link(list()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Stops the CubQ process"
  @spec stop() :: :ok
  def stop() do
    GenServer.stop(__MODULE__, :normal)
  catch
    :exit, _ -> :ok
  end

  @impl WorkList
  def new(expiration_fn, update_expiration_fn, max_size \\ @default_max_size) do
    :ok = GenServer.call(__MODULE__, {:new, expiration_fn, update_expiration_fn, max_size})
    __MODULE__
  end

  @impl WorkList
  def peek(work_list) do
    GenServer.call(work_list, :peek)
  end

  @impl WorkList
  def push(work_list, item) do
    :ok = GenServer.call(work_list, {:push, item})
    work_list
  end

  @impl WorkList
  def pop(work_list) do
    :ok = GenServer.call(work_list, :pop)
    work_list
  end

  @impl WorkList
  def pending(work_list, ref) do
    :ok = GenServer.call(work_list, {:pending, ref})
    work_list
  end

  @impl WorkList
  def reset_pending(work_list) do
    :ok = GenServer.call(work_list, :reset_pending)
    work_list
  end

  @impl WorkList
  def done(work_list, ref) do
    item = GenServer.call(work_list, {:done, ref})
    {work_list, item}
  end

  @impl WorkList
  def count(work_list) do
    GenServer.call(work_list, :count)
  end

  @impl WorkList
  def count_pending(work_list) do
    GenServer.call(work_list, :count_pending)
  end

  @impl WorkList
  def empty?(work_list), do: peek(work_list) == nil

  @impl WorkList
  def remove_all(work_list) do
    :ok = GenServer.call(work_list, :remove_all)
    work_list
  end

  @impl GenServer
  def init(opts) do
    data_dir = Keyword.get(opts, :data_dir, "/data/jackalope")
    queue_name = Keyword.get(opts, :queue_name, :items)

    db =
      case CubDB.start_link(data_dir: data_dir, name: :work_list, auto_compact: true) do
        {:ok, pid} ->
          pid

        {:error, {:already_started, pid}} ->
          pid

        other ->
          Logger.warn("[Jackalope] Corrupted DB : #{inspect(other)}. Erasing it.")
          _ = File.rmdir(data_dir)
          raise "Corrupted work list DB"
      end

    CubDB.set_auto_file_sync(db, true)

    queue =
      case CubQ.start_link(db: db, queue: queue_name) do
        {:ok, pid} ->
          pid

        {:error, {:already_started, pid}} ->
          pid

        other ->
          Logger.warn("[Jackalope] Corrupted queue : #{inspect(other)}. Erasing DB.")
          _ = File.rmdir(data_dir)
          raise "Corrupted work list queue"
      end

    send(self(), :tick)

    {:ok,
     %State{
       db: db,
       queue: queue,
       queue_name: queue_name,
       max_work_list_size: nil
     }}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    :ok = record_time_now(state)
    Process.send_after(self(), :tick, @tick_delay)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:new, expiration_fn, update_expiration_fn, max_size}, _from, state) do
    # Re-queue pending items, rebasing their expiration with the new monotonic system time
    recover(state, expiration_fn, update_expiration_fn)

    CubDB.put(state.db, :pending, %{})

    {:reply, :ok, %State{state | expiration_fn: expiration_fn, max_work_list_size: max_size}}
  end

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
    pending_items = pending_items(state)

    :ok = Enum.each(pending_items, &(:ok = CubQ.push(state.queue, &1)))

    :ok = update_pending(state, %{})

    {:reply, :ok, bound_work_items(state)}
  end

  @impl GenServer
  def terminate(_reason, state) do
    record_time_now(state)
  end

  defp add_pending(state, item, ref) do
    updated_pending = get_pending(state) |> Map.put(ref, item) |> bound_pending_items(state)

    :ok = update_pending(state, updated_pending)
  end

  defp pending_items(state), do: get_pending(state) |> Map.values()

  defp bound_work_items(state) do
    max = state.max_work_list_size

    if queue_size(state) > max do
      :ok = remove_expired_work_items(state)
      excess = queue_size(state) - max

      _ =
        if excess >= 0 do
          Enum.each(
            1..excess,
            fn _i ->
              {:ok, item_removed} = CubQ.dequeue(state.queue)

              Logger.info(
                "[Jackalope] WorkList - The worklist still exceeds #{max}. #{inspect(item_removed)} was removed from the queue."
              )
            end
          )
        end
    end

    state
  end

  defp remove_expired_work_items(state) do
    Enum.each(
      1..queue_size(state),
      fn _i ->
        # remove from begining
        {:ok, item} = CubQ.dequeue(state.queue)

        if WorkList.unexpired?(item, state.expiration_fn) do
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

  # Trim pending as needed to accomodate an additional pending item
  defp bound_pending_items(pending, state) do
    if map_size(pending) > state.max_work_list_size do
      # Trim expired pending requests
      kept_pairs =
        Enum.reduce(
          pending,
          [],
          fn {ref, item}, acc ->
            if WorkList.unexpired?(item, state.expiration_fn) do
              [{ref, item} | acc]
            else
              acc
            end
          end
        )

      # If still over maximum, remove the oldest pending request (expiration is smallest)
      if length(kept_pairs) > state.max_work_list_size do
        [{ref, item} | newer_pairs] =
          Enum.sort(kept_pairs, fn {_, item1}, {_, item2} ->
            WorkList.after?(state.expiration_fn.(item2), state.expiration_fn.(item1))
          end)

        Logger.warn(
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
    :ok = CubDB.put(state.db, :latest_time, WorkList.now())
  end

  # After restart, recover and rebase the persisted items from the previous to the new system monotonic time.
  # Assumes that restart occurred shortly after shutdown, or this is the first time the work list was created.
  defp recover(state, expiration_fn, update_expiration_fn) do
    # latest_time is nil if this is a never-persisted work list
    latest_time = CubDB.get(state.db, :latest_time)
    now = WorkList.now()
    # Rebase the expiration of queued (waiting) items
    items_count = queue_size(state)

    if items_count > 0 do
      Enum.each(
        1..items_count,
        fn _i ->
          {:ok, waiting_item} = CubQ.dequeue(state.queue)
          expiration = WorkList.rebase_expiration(expiration_fn.(waiting_item), latest_time, now)
          :ok = CubQ.enqueue(state.queue, update_expiration_fn.(waiting_item, expiration))
        end
      )
    end

    # Convert pending items into waiting items with rebased expirations

    pending_items(state)
    |> Enum.each(fn pending_item ->
      expiration = WorkList.rebase_expiration(expiration_fn.(pending_item), latest_time, now)
      :ok = CubQ.enqueue(state.queue, update_expiration_fn.(pending_item, expiration))
    end)
  end
end
