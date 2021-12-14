defmodule Jackalope.WorkList do
  @moduledoc """
  A genserver wrapper for CubQ which we leverage to store and restore worklist tasks during disconnections
  """
  use GenServer
  require Logger

  @doc "Starts the CubQ process"
  @spec start_link(keyword()) :: GenServer.on_start()
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
    Logger.debug("[Jackalope] WorkList - Pushed #{inspect(item)}")
    GenServer.call(__MODULE__, {:push, item})
  end

  @doc "Pops the most recently added work item off the CubQ stack"
  @spec pop :: nil | tuple()
  def pop() do
    item = GenServer.call(__MODULE__, :pop)
    Logger.debug("[Jackalope] WorkList - Popped #{inspect(item)}")
    item
  end

  @doc false
  @spec size() :: non_neg_integer()
  def size() do
    GenServer.call(__MODULE__, :size)
  end

  @doc false
  @spec remove_all() :: :ok
  def remove_all() do
    GenServer.cast(__MODULE__, :remove_all)
  end

  @impl GenServer
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    db_name = Keyword.fetch!(opts, :db_name)
    queue_name = Keyword.fetch!(opts, :queue_name)
    list_max = Keyword.fetch!(opts, :max_work_list_size)

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

    remove_expired(state)
    excess = size(state) + 1 - max

    remove_excess(state, excess)

    expiration = expiration(item)
    {:reply, CubQ.push(state.queue, {item, expiration}), state}
  end

  def handle_call(:size, _from, state) do
    {:reply, size(state), state}
  end

  @impl GenServer
  def handle_cast(:remove_all, state) do
    :ok = CubQ.delete_all(state.queue)
    {:noreply, state}
  end

  defp remove_expired(state) do
    case CubQ.peek_first(state.queue) do
      {:ok, item_with_expiration} ->
        if keep?(item_with_expiration) do
          :ok
        else
          {:ok, _} = CubQ.dequeue(state.queue)
          remove_expired(state)
        end

      _ ->
        :ok
    end
  end

  defp remove_excess(_state, excess) when excess <= 0, do: :ok

  defp remove_excess(state, excess) do
    {:ok, _} = CubQ.dequeue(state.queue)
    remove_excess(state, excess - 1)
  end

  defp size(state), do: CubDB.size(state.db)

  defp keep?({_item, :infinity}), do: true

  defp keep?({_item, expiration}), do: expiration >= System.monotonic_time(:second)

  defp ttl({_cmd, opts}), do: Keyword.get(opts, :ttl, :infinity)

  defp expiration(item) do
    case ttl(item) do
      :infinity -> :infinity
      seconds -> System.monotonic_time(:second) + seconds
    end
  end
end
