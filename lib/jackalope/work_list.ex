defmodule Jackalope.WorkList do
  @moduledoc """
  A genserver wrapper for CubQ which we leverage to store and restore worklist tasks during disconnections
  """
  use GenServer

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
  @spec init(keyword) ::
          {:ok, %{db: atom | pid | {atom, any} | {:via, atom, any}, queue: any, queue_name: any}}
  def init(opts) do
    data_dir = Keyword.get(opts, :data_dir)
    db_name = Keyword.get(opts, :db_name)
    queue_name = Keyword.get(opts, :queue_name)

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

    {:ok, %{db: db, queue: queue, queue_name: queue_name}}
  end

  @impl GenServer
  def handle_call({:push, item}, _from, state) do
    read_cubdb(state)
    {:reply, CubQ.push(state.queue, item), state}
  end

  @impl GenServer
  def handle_call(:pop, _from, state) do
    {:reply, CubQ.pop(state.queue), state}
  end

  defp read_cubdb(state) do
    state.db
    |> CubDB.current_db_file()
    |> File.read()
    |> IO.inspect(label: "CubDB contents")
  end
end
