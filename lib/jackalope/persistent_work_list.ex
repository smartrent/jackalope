defmodule Jackalope.PersistentWorkList do
  @moduledoc """
  A work list whose work items are persisted as individual files.
  """

  alias Jackalope.Persistent.ItemFile
  alias Jackalope.Persistent.Meta
  alias Jackalope.Persistent.Recovery

  require Logger

  defstruct bottom_index: 0,
            next_index: 0,
            expirations: %{},
            pending: %{},
            data_dir: nil,
            max_size: nil,
            persisted_timestamp: 0

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
          # The most recently persisted Jackalope timestamp
          persisted_timestamp: Timestamp.t()
        }

  @doc "Create a new work list"
  @spec new(Keyword.t()) :: t()
  def new(opts \\ []) do
    Logger.info("[Jackalope] Starting #{__MODULE__} with #{inspect(opts)}")

    initial_state = %__MODULE__{
      max_size: Keyword.get(opts, :max_size),
      data_dir: Keyword.fetch!(opts, :data_dir)
    }

    Recovery.recover(initial_state)
  end

  @spec reset_state(t()) :: t()
  def reset_state(work_list) do
    %{
      work_list
      | bottom_index: 0,
        next_index: 0,
        pending: %{},
        expirations: %{}
    }
  end
end

defimpl Jackalope.WorkList, for: Jackalope.PersistentWorkList do
  alias Jackalope.Persistent.ItemFile
  alias Jackalope.Persistent.Meta

  require Logger

  @impl Jackalope.WorkList
  def info(work_list) do
    %{count_waiting: count(work_list), count_pending: count_pending(work_list)}
  end

  @impl Jackalope.WorkList
  def peek(work_list) do
    # Peek at oldest non-pending work item
    if empty?(work_list) do
      nil
    else
      # If this fails, let it crash
      {:ok, item} = ItemFile.load(work_list, work_list.bottom_index)
      item
    end
  end

  @impl Jackalope.WorkList
  def latest_known_state(work_list) do
    %{timestamp: work_list.persisted_timestamp, id: work_list.next_index}
  end

  @impl Jackalope.WorkList
  def push(work_list, item, now) do
    work_list
    |> add_item(item)
    |> bound_items(now)
  end

  @impl Jackalope.WorkList
  def pop(work_list) do
    index = work_list.bottom_index
    ItemFile.delete(work_list, index)

    %{work_list | expirations: Map.delete(work_list.expirations, index)}
    |> move_bottom_index()
  end

  @impl Jackalope.WorkList
  def sync(work_list, now) do
    Meta.save(work_list, now)
    %{work_list | persisted_timestamp: now}
  end

  @impl Jackalope.WorkList
  def pending(work_list, ref, _now) do
    # The item becoming pending is always the one at bottom index
    %{work_list | pending: Map.put(work_list.pending, ref, work_list.bottom_index)}
    |> move_bottom_index()
  end

  @impl Jackalope.WorkList
  def done(work_list, ref) do
    case Map.get(work_list.pending, ref) do
      nil ->
        Logger.warn(
          "[Jackalope] Unknown pending work list item reference #{inspect(ref)}. Ignored."
        )

        {work_list, nil}

      index ->
        {:ok, item} = ItemFile.load(work_list, index)
        ItemFile.delete(work_list, index)
        updated_work_list = %{work_list | pending: Map.delete(work_list.pending, ref)}

        {updated_work_list, item}
    end
  end

  @impl Jackalope.WorkList
  def remove_all(work_list) do
    _ = File.rm_rf(work_list.data_dir)
    :ok = File.mkdir_p!(work_list.data_dir)

    Jackalope.PersistentWorkList.reset_state(work_list)
  end

  @impl Jackalope.WorkList
  def reset_pending(work_list) do
    bottom_index =
      case bottom_pending_index(work_list) do
        nil -> work_list.bottom_index
        index -> index
      end

    %{work_list | bottom_index: bottom_index, pending: %{}}
  end

  ## PRIVATE
  defp count(state) do
    expired_count =
      Enum.count(
        state.bottom_index..(state.next_index - 1),
        &item_vanished?(&1, state)
      )

    (state.next_index - state.bottom_index - expired_count)
    |> max(0)
  end

  defp count_pending(state), do: Enum.count(state.pending)

  # Ought to be the same as Enum.count(state.expirations)
  defp persisted_count(state), do: count(state) + count_pending(state)

  defp add_item(state, item) do
    ItemFile.save(state, item)

    %{
      state
      | expirations: Map.put(state.expirations, item.id, item.expiration),
        next_index: max(state.next_index, item.id + 1)
    }
  end

  # Move bottom index up until it is not an expired
  defp move_bottom_index(state) do
    next_bottom_index = state.bottom_index + 1

    cond do
      next_bottom_index > state.next_index ->
        state

      item_vanished?(next_bottom_index, state) ->
        %{state | bottom_index: next_bottom_index}
        |> move_bottom_index()

      next_bottom_index <= state.next_index ->
        %{state | bottom_index: next_bottom_index}
    end
  end

  # No non-pending items?
  defp empty?(state), do: state.bottom_index == state.next_index

  defp item_vanished?(index, state) do
    not ItemFile.exists?(state, index)
  end

  defp bottom_pending_index(state) do
    if Enum.empty?(state.pending), do: nil, else: Enum.min(Map.values(state.pending))
  end

  defp bound_items(state, now) do
    max = state.max_size

    if persisted_count(state) > max do
      updated_state = remove_expired_items(state, now)
      excess_count = persisted_count(updated_state) - max

      remove_excess(excess_count, updated_state)
    else
      state
    end
  end

  # Remove expired, persisted items, whether pending or not.
  defp remove_expired_items(state, now) do
    if empty?(state) do
      state
    else
      Enum.reduce(
        Map.keys(state.expirations),
        state,
        fn index, acc ->
          maybe_expire(index, acc, now)
        end
      )
    end
  end

  defp expiration(index, state) do
    Map.fetch!(state.expirations, index)
  end

  defp maybe_expire(index, state, now) do
    if item_vanished?(index, state) do
      state
    else
      expiration = expiration(index, state)

      if expiration >= now do
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
        |> Enum.reject(&item_vanished?(&1, state))
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
    ItemFile.delete(state, index)

    updated_state =
      cond do
        pending_item?(index, state) ->
          %{state | pending: Map.delete(state.pending, index)}

        index == state.bottom_index ->
          move_bottom_index(state)

        true ->
          state
      end

    %{updated_state | expirations: Map.delete(state.expirations, index)}
  end

  defp pending_item?(index, state), do: Map.has_key?(state.pending, index)
end
