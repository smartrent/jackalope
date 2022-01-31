defmodule Jackalope.PersistentWorkList do
  @moduledoc """
  A work list whose work items are persisted as individual files.
  """

  use GenServer

  alias Jackalope.WorkList.Expiration

  require Logger

  @tick_delay 10 * 60 * 1_000

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            # The maximum number of items that can be persisted as files
            max_size: non_neg_integer(),
            # The lowest index of an unexpired, not-pending item. No pending item has an index >= bottom_index.
            bottom_index: non_neg_integer(),
            # The index at which the next item will be pushed.
            next_index: non_neg_integer(),
            # Cache of item expiration times for all persisted items (pending and not)
            expirations: %{required(non_neg_integer()) => integer},
            # Indices of pending items mapped by their references.
            pending: %{required(reference()) => non_neg_integer()},
            # The file directory persists items waiting execution or pending confirmation of execution.
            data_dir: String.t(),
            # The function to use to get an expiration given the item
            expiration_fn: fun(),
            # Delta between the (approximate) monotonic time at last reboot and the monotomic time at startup
            delta_time: integer(),
            # The highest index of a recovered item, -1 if none
            recovery_index: integer
          }

    defstruct bottom_index: 0,
              next_index: 0,
              expirations: %{},
              pending: %{},
              data_dir: nil,
              max_size: nil,
              expiration_fn: nil,
              delta_time: 0,
              recovery_index: -1
  end

  @doc "Create a new work list"
  @spec new(Keyword.t()) :: pid()
  def new(opts \\ []) do
    Logger.info("[Jackalope] Starting #{__MODULE__} with #{inspect(opts)}")
    {:ok, pid} = GenServer.start_link(__MODULE__, opts)
    pid
  end

  @impl GenServer
  def init(opts) do
    send(self(), :tick)

    initial_state =
      %State{
        max_size: Keyword.get(opts, :max_size),
        data_dir: Keyword.fetch!(opts, :data_dir),
        expiration_fn: Keyword.fetch!(opts, :expiration_fn)
      }
      |> recover()

    record_time_now(initial_state)
    {:ok, initial_state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    :ok = record_time_now(state)
    Process.send_after(self(), :tick, @tick_delay)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:count, _from, state) do
    {:reply, count(state), state}
  end

  def handle_call(:count_pending, _from, state) do
    {:reply, count_pending(state), state}
  end

  def handle_call(:peek, _from, state) do
    {:reply, peek_oldest(state), state}
  end

  def handle_call({:push, item}, _from, state) do
    updated_state = add_item(item, state)
    {:reply, :ok, bound_items(updated_state)}
  end

  def handle_call(:pop, _from, state) do
    updated_state = remove_oldest(state)
    {:reply, :ok, updated_state}
  end

  # The item becoming pending is always the one at bottom index
  def handle_call({:pending, ref}, _from, state) do
    updated_state =
      %State{state | pending: Map.put(state.pending, ref, state.bottom_index)}
      |> move_bottom_index()

    {:reply, :ok, updated_state}
  end

  def handle_call({:done, ref}, _from, state) do
    case Map.get(state.pending, ref) do
      nil ->
        Logger.warn(
          "[Jackalope] Unknown pending work list item reference #{inspect(ref)}. Ignored."
        )

        {:reply, nil, state}

      index ->
        {:ok, item} = stored_item_at(index, state, remove: true)
        updated_state = %State{state | pending: Map.delete(state.pending, ref)}

        {:reply, item, updated_state}
    end
  end

  def handle_call(:remove_all, _from, state) do
    {:ok, _} = File.rm_rf(state.data_dir)
    :ok = File.mkdir_p!(state.data_dir)
    record_time_now(state)

    {:reply, :ok, reset_state(state)}
  end

  def handle_call(:reset_pending, _from, state) do
    bottom_index =
      case bottom_pending_index(state) do
        nil -> state.bottom_index
        index -> index
      end

    {:reply, :ok, %State{state | bottom_index: bottom_index, pending: %{}}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    record_time_now(state)
  end

  ## PRIVATE

  defp count(state) do
    expired_count =
      Enum.count(
        state.bottom_index..(state.next_index - 1),
        &expired?(&1, state)
      )

    (state.next_index - state.bottom_index - expired_count)
    |> max(0)
  end

  defp count_pending(state), do: Enum.count(state.pending)

  # Ought to be the same as Enum.count(state.expirations)
  defp persisted_count(state), do: count(state) + count_pending(state)

  defp record_time_now(state) do
    time = Expiration.now() |> Integer.to_string()
    new_time_path = Path.join(state.data_dir, "new_time")
    time_path = Path.join(state.data_dir, "time")
    :ok = File.write!(new_time_path, time, [:write])
    :ok = File.rename!(new_time_path, time_path)
  end

  # Peek at oldest non-pending work item
  defp peek_oldest(state) do
    if empty?(state) do
      nil
    else
      # If this fails, let it crash
      {:ok, item} = stored_item_at(state.bottom_index, state)
      item
    end
  end

  defp add_item(item, state) do
    index = state.next_index
    :ok = store_item(item, index, state)
    expiration = state.expiration_fn.(item)

    %State{
      state
      | next_index: index + 1,
        expirations: Map.put(state.expirations, index, expiration)
    }
  end

  defp remove_oldest(state) do
    index = state.bottom_index
    path = item_file_path(index, state)
    # If this fails, let it crash
    :ok = File.rm!(path)

    %State{state | expirations: Map.delete(state.expirations, index)}
    |> move_bottom_index()
  end

  # Move bottom index up until it is not an expired
  defp move_bottom_index(state) do
    next_bottom_index = state.bottom_index + 1

    cond do
      next_bottom_index > state.next_index ->
        state

      expired?(next_bottom_index, state) ->
        %State{
          state
          | bottom_index: next_bottom_index
        }
        |> move_bottom_index()

      next_bottom_index <= state.next_index ->
        %State{
          state
          | bottom_index: next_bottom_index
        }
    end
  end

  # No non-pending items?
  defp empty?(state), do: state.bottom_index == state.next_index

  defp expired?(index, state) do
    path = item_file_path(index, state)
    not File.exists?(path)
  end

  defp bottom_pending_index(state) do
    if Enum.empty?(state.pending), do: nil, else: Enum.min(Map.values(state.pending))
  end

  defp store_item(item, index, state) do
    path = item_file_path(index, state)
    if File.exists?(path), do: raise("Overwritting item file")
    binary = item_to_binary(item)
    File.write!(path, binary)
  end

  # Returns {:ok, any()} | {:error, :not_found}
  defp stored_item_at(index, state, opts \\ []) do
    path = item_file_path(index, state)

    case File.read(path) do
      {:ok, binary} ->
        _ = if Keyword.get(opts, :remove, false), do: File.rm(path)

        item_from_binary(binary)

      {:error, :not_found} ->
        Logger.warn("[Jackalope] File not found #{inspect(path)}}")

        {:error, :not_found}
    end
  end

  defp item_file_path(index, state) do
    Path.join(state.data_dir, "#{index}.item")
  end

  defp item_from_binary(binary) do
    item = :erlang.binary_to_term(binary)
    {:ok, item}
  rescue
    error ->
      Logger.warn("[Jackalope] Failed to convert work item from binary: #{inspect(error)}")
      {:error, :invalid}
  end

  defp item_to_binary(item), do: :erlang.term_to_binary(item)

  defp bound_items(state) do
    max = state.max_size

    if persisted_count(state) > max do
      updated_state = remove_expired_items(state)
      excess_count = persisted_count(updated_state) - max

      remove_excess(excess_count, updated_state)
    else
      state
    end
  end

  # Remove expired, persisted items, whether pending or not.
  defp remove_expired_items(state) do
    if empty?(state) do
      state
    else
      Enum.reduce(
        Map.keys(state.expirations),
        state,
        fn index, acc ->
          maybe_expire(index, acc)
        end
      )
    end
  end

  defp expiration(index, state) do
    expiration = Map.fetch!(state.expirations, index)
    if index <= state.recovery_index, do: expiration + state.delta_time, else: expiration
  end

  defp maybe_expire(index, state) do
    if expired?(index, state) do
      state
    else
      expiration = expiration(index, state)

      if Expiration.after?(expiration, Expiration.now()) do
        state
      else
        Logger.info("[Jackalope] Expiring persistent work list item at #{index}")
        forget_item(index, state)
      end
    end
  end

  defp remove_excess(excess_count, state) when excess_count <= 0, do: state

  # Try removing excess_count persisted items but don't touch pending items.
  # Remove items closest to expiration first
  defp remove_excess(excess_count, state) do
    if empty?(state) do
      state
    else
      live_indices =
        state.bottom_index..(state.next_index - 1)
        |> Enum.reject(&expired?(&1, state))
        |> Enum.sort(fn index1, index2 ->
          expiration(index1, state) <= expiration(index2, state)
        end)
        |> Enum.take(excess_count)

      Enum.reduce(
        live_indices,
        state,
        fn index, acc -> forget_item(index, acc) end
      )
    end
  end

  # Forget persisted item, whether pending or not
  defp forget_item(index, state) do
    path = item_file_path(index, state)
    :ok = File.rm!(path)

    updated_state =
      cond do
        pending_item?(index, state) ->
          %State{state | pending: Map.delete(state.pending, index)}

        index == state.bottom_index ->
          move_bottom_index(state)

        true ->
          state
      end

    %State{updated_state | expirations: Map.delete(state.expirations, index)}
  end

  defp pending_item?(index, state), do: Map.has_key?(state.pending, index)

  defp recover(state) do
    :ok = File.mkdir_p!(state.data_dir)

    delta_time = Expiration.now() - latest_time(state)

    item_files =
      File.ls!(state.data_dir)
      |> Enum.filter(&Regex.match?(~r/.*\.item/, &1))

    expirations =
      item_files
      |> Enum.reduce(
        [],
        fn item_file, acc ->
          index = index_of_item_file(item_file)

          case stored_item_at(index, state) do
            {:ok, item} ->
              expiration = state.expiration_fn.(item)
              [{index, expiration} | acc]

            {:error, reason} ->
              Logger.warn(
                "Failed to recover item in #{inspect(item_file)}: #{inspect(reason)}. Removing it."
              )

              _ = File.rm(item_file_path(index, state))
              acc
          end
        end
      )
      |> Enum.into(%{})

    item_indices = Map.keys(expirations)

    if Enum.empty?(item_files) do
      reset_state(state)
    else
      bottom_index = Enum.min(item_indices)
      last_index = Enum.max(item_indices)

      %State{
        state
        | bottom_index: bottom_index,
          next_index: last_index + 1,
          recovery_index: last_index,
          delta_time: delta_time,
          expirations: expirations
      }
      |> bound_items()
    end
  end

  defp index_of_item_file(item_file) do
    [index_s, _] = String.split(item_file, ".")
    {index, _} = Integer.parse(index_s)
    index
  end

  defp reset_state(state) do
    %State{
      state
      | bottom_index: 0,
        next_index: 0,
        pending: %{},
        expirations: %{},
        recovery_index: -1
    }
  end

  defp latest_time(state) do
    path = Path.join(state.data_dir, "time")

    if File.exists?(path) do
      time_s = File.read!(path)

      case Integer.parse(time_s) do
        {time, _} ->
          time

        other ->
          Logger.warn("[Jackalope] Invalid stored latest time: #{inspect(other)}")
          Expiration.now()
      end
    else
      Logger.info("[Jackalope] No latest time found for recovery. Using now.")
      Expiration.now()
    end
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
