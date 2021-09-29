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
    GenServer.call(__MODULE__, {:push, item})
  end

  @doc "Pops the most recently added work item off the CubQ stack"
  @spec pop :: nil | tuple()
  def pop() do
    GenServer.call(__MODULE__, :pop)
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

    {:ok, %{db: db, queue: queue, queue_name: queue_name, max_work_list_size: list_max}}
  end

  @impl GenServer
  def handle_call(:pop, _from, state) do
    {:reply, CubQ.pop(state.queue), state}
  end

  @impl GenServer
  def handle_call({:push, item}, _from, state) do
    max = state.max_work_list_size
    first_count = CubDB.size(state.db)
    if first_count > max do
      remove_expired(state, first_count)
    end

    second_count = CubDB.size(state.db)
    if second_count > max do
      {:ok, item_to_be_removed} = CubQ.dequeue(state.queue)
      Logger.warn("[Jackalope] The worklist exceeds #{max}. #{item_to_be_removed} will be removed from the queue.")
    end

    {:reply, CubQ.push(state.queue, item), state}
  end

  defp remove_expired(state, count) do
    for _i <- 1..count do
      {:ok, item} = CubQ.dequeue(state.queue)
      if keep?(item) do
        CubQ.push(state.queue, item)
      else
        Logger.warn("[Jackalope] #{item} removed from the queue due to size constraints.")
      end
    end
  end

  defp keep?({:ok, item}) do
    now = System.monotonic_time(:millisecond)
    ttl = Keyword.get(item, :ttl, :infinity)
    ttl > now
  end

end
