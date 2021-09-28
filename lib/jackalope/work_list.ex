defmodule Jackalope.WorkList do
  @moduledoc """
  A genserver wrapper for CubQ which we leverage to store and restore worklist tasks during disconnections
  """
  use GenServer
  require Logger

  @doc "Starts the CubQ process"
  @spec start_link(list()) :: :ignore | {:error, any} | {:ok, pid}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Stops the CubQ process"
  @spec stop :: :ok
  def stop() do
    GenServer.stop(__MODULE__, :normal)
  catch
    :exit, _ -> :ok
  end

  @doc "Pushes a work item onto the CubQ stack"
  @spec push(any) :: :ok
  def push(item) do
    Logger.info("[Jackalope] WorkList - PUSH #{inspect(item)}")
    GenServer.call(__MODULE__, {:push, item})
  end

  @doc "Pops the most recently added work item off the CubQ stack"
  @spec pop :: nil | tuple()
  def pop() do
    item = GenServer.call(__MODULE__, :pop)
    Logger.info("[Jackalope] WorkList - POPPED #{inspect(item)}")
    item
  end

  @doc false
  def size() do
    GenServer.call(__MODULE__, :size)
  end

  @doc false
  def remove_all() do
    GenServer.cast(__MODULE__, :remove_all)
  end

  @impl GenServer
  def init(opts) do
    data_dir = Keyword.get(opts, :data_dir)
    db_name = Keyword.get(opts, :db_name)
    queue_name = Keyword.get(opts, :queue_name)
    list_max = Keyword.get(opts, :max_work_list_size)

    db =
      case CubDB.start_link(data_dir: data_dir, name: db_name, auto_compact: true) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    CubDB.set_auto_file_sync(db, false)

    queue =
      case CubQ.start_link(db: db, queue: queue_name) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    {:ok,
     %{
       db: db,
       queue: queue,
       queue_name: queue_name,
       max_work_list_size: list_max
     }}
  end

  @impl GenServer
  def handle_call(:pop, _from, state) do
    result =
      case CubQ.pop(state.queue) do
        {:ok, {item, _expiration}} -> {:ok, item}
        nil -> nil
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:push, item}, _from, state) do
    max = state.max_work_list_size

    _ =
      if size(state) >= max do
        _ = remove_expired(state)
        excess = size(state) - max

        if excess >= 0 do
          # Make room for the new item if at max or more
          for _i <- 1..(excess + 1) do
            {:ok, item_removed} = CubQ.dequeue(state.queue)

            Logger.warn(
              "[Jackalope] WorkList - The worklist still exceeds #{max}. #{inspect(item_removed)} was removed from the queue."
            )
          end
        end
      end

    expiration = expiration(item)
    {:reply, CubQ.push(state.queue, {item, expiration}), state}
  end

  def handle_call(:size, _from, state) do
    {:reply, size(state), state}
  end

  @impl GenServer
  def handle_cast(:remove_all, state) do
    _ = CubQ.delete_all(state.queue)
    {:noreply, state}
  end

  defp remove_expired(state) do
    Logger.info("[Jackalope] WorkList - Removing expired work orders")

    for _i <- 1..size(state) do
      # remove from begining
      {:ok, item_with_expiration} = CubQ.dequeue(state.queue)

      if keep?(item_with_expiration) do
        Logger.debug("[Jackalope] WorkList - Keeping #{inspect(item_with_expiration)}")
        # same as push (insert at end)
        :ok = CubQ.enqueue(state.queue, item_with_expiration)
      else
        Logger.warn(
          "[Jackalope] #{inspect(item_with_expiration)} removed from the queue due to expiration. Size is #{size(state)}"
        )
      end
    end
  end

  defp size(state), do: CubDB.size(state.db)

  defp keep?({_item, expiration}) do
    now = System.monotonic_time(:second)
    expiration == :infinity or expiration >= now
  end

  defp ttl({_cmd, opts}), do: Keyword.get(opts, :ttl, :infinity)

  defp expiration(item) do
    case ttl(item) do
      :infinity -> :infinity
      seconds -> System.monotonic_time(:second) + seconds
    end
  end
end
