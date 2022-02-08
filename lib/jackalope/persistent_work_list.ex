defmodule Jackalope.PersistentWorkList do
  @moduledoc """
  A work list whose work items are persisted as individual files.
  """

  alias Jackalope.Item
  alias Jackalope.Persistent.ItemFile
  alias Jackalope.Persistent.Meta
  alias Jackalope.Persistent.Recovery
  alias Jackalope.Timestamp

  require Logger

  defstruct count: 0,
            next_index: 0,
            items_to_send: [],
            items_in_transit: %{},
            data_dir: nil,
            max_size: nil,
            persisted_timestamp: 0

  @type t :: %__MODULE__{
          # The maximum number of items that can be persisted as files
          max_size: non_neg_integer(),
          # The current number of items being tracked
          count: non_neg_integer(),
          # The index at which the next item will be pushed.
          next_index: non_neg_integer(),
          # Cache of items
          items_to_send: [Item.t()],
          # Pending items
          items_in_transit: %{reference() => Item.t()},
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
      | count: 0,
        next_index: 0,
        items_to_send: [],
        items_in_transit: %{}
    }
  end

  @spec check_consistency(t()) :: :ok
  def check_consistency(work_list) do
    count = Enum.count(work_list.items_to_send) + Enum.count(work_list.items_in_transit)
    unless count == work_list.count, do: raise("Count mismatch")

    Enum.each(work_list.items_to_send, fn item ->
      {:ok, persisted_item} = ItemFile.load(work_list, item.id)

      unless persisted_item == item,
        do: raise("To send item mismatch: #{inspect(persisted_item)} (expected #{inspect(item)})")
    end)

    Enum.each(work_list.items_in_transit, fn {_ref, item} ->
      {:ok, persisted_item} = ItemFile.load(work_list, item.id)

      unless persisted_item == item,
        do:
          raise(
            "In transit item mismatch: #{inspect(persisted_item)} (expected #{inspect(item)})"
          )
    end)

    :ok
  end
end

defimpl Jackalope.WorkList, for: Jackalope.PersistentWorkList do
  alias Jackalope.Persistent.ItemFile
  alias Jackalope.Persistent.Meta

  require Logger

  @impl Jackalope.WorkList
  def info(work_list) do
    %{
      count_waiting: Enum.count(work_list.items_to_send),
      count_pending: Enum.count(work_list.items_in_transit)
    }
  end

  @impl Jackalope.WorkList
  def peek(work_list) do
    List.first(work_list.items_to_send)
  end

  @impl Jackalope.WorkList
  def latest_known_state(work_list) do
    %{timestamp: work_list.persisted_timestamp, id: work_list.next_index}
  end

  @impl Jackalope.WorkList
  def push(work_list, item, now) do
    if item.expiration >= now do
      work_list
      |> make_room(now)
      |> add_item(item)
    else
      work_list
    end
  end

  @impl Jackalope.WorkList
  def pop(work_list) do
    item = hd(work_list.items_to_send)
    ItemFile.delete(work_list, item.id)

    %{work_list | items_to_send: tl(work_list.items_to_send), count: work_list.count - 1}
  end

  @impl Jackalope.WorkList
  def sync(work_list, now) do
    Meta.save(work_list, now)
    %{work_list | persisted_timestamp: now}
  end

  @impl Jackalope.WorkList
  def pending(work_list, ref, _now) do
    # The item becoming pending is always head of the items_to_send list
    %{
      work_list
      | items_to_send: tl(work_list.items_to_send),
        items_in_transit: Map.put(work_list.items_in_transit, ref, hd(work_list.items_to_send))
    }
  end

  @impl Jackalope.WorkList
  def done(work_list, ref) do
    case Map.fetch(work_list.items_in_transit, ref) do
      :error ->
        Logger.warn(
          "[Jackalope] Unknown pending work list item reference #{inspect(ref)}. Ignored."
        )

        {work_list, nil}

      {:ok, item} ->
        ItemFile.delete(work_list, item.id)

        updated_work_list = %{
          work_list
          | items_in_transit: Map.delete(work_list.items_in_transit, ref),
            count: work_list.count - 1
        }

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
    %{
      work_list
      | items_to_send: Map.values(work_list.items_in_transit) ++ work_list.items_to_send,
        items_in_transit: %{}
    }
  end

  ## PRIVATE
  defp add_item(state, item) do
    ItemFile.save(state, item)

    %{
      state
      | items_to_send: [item | state.items_to_send],
        count: state.count + 1,
        next_index: max(state.next_index, item.id + 1)
    }
  end

  defp make_room(%{count: count, max_size: max_size} = state, now) when count >= max_size do
    state
    |> gc(now)
    |> drop_one()
  end

  defp make_room(state, _now), do: state

  defp drop_one(%{items_in_transit: items_in_transit} = state) when items_in_transit != %{} do
    # Drop a random item that's in transit.
    {ref, item} = Map.to_list(items_in_transit) |> hd()
    ItemFile.delete(state, item.id)
    %{state | items_in_transit: Map.delete(items_in_transit, ref), count: state.count - 1}
  end

  defp drop_one(state) do
    item = state.items_to_send |> hd()
    ItemFile.delete(state, item.id)
    %{state | items_to_send: tl(state.items_to_send), count: state.count - 1}
  end

  # Remove expired, persisted items, whether pending or not.
  defp gc(state, now) do
    {removed, new_items_to_send} =
      Enum.reduce(state.items_to_send, {0, []}, &gc_item_to_send(&1, &2, state, now))

    {removed, new_items_in_transit} =
      Enum.reduce(state.items_in_transit, {removed, %{}}, &gc_item_in_transit(&1, &2, state, now))

    %{
      state
      | items_to_send: new_items_to_send,
        items_in_transit: Map.new(new_items_in_transit),
        count: state.count - removed
    }
  end

  defp gc_item_to_send(item, {removed, result}, state, now) do
    if item.expiration < now do
      ItemFile.delete(state, item.id)
      {removed + 1, result}
    else
      {removed, [item | result]}
    end
  end

  defp gc_item_in_transit({_ref, item} = kv, {removed, result}, state, now) do
    if item.expiration < now do
      ItemFile.delete(state, item.id)
      {removed + 1, result}
    else
      {removed, [kv | result]}
    end
  end
end
