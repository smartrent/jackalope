defmodule Jackalope.TransientWorkList do
  @moduledoc """
  A simple work list that does not survive across reboots.
  """

  alias Jackalope.Item
  alias Jackalope.Timestamp

  require Logger

  @default_max_size 100

  defstruct items: [],
            pending: %{},
            max_size: @default_max_size

  @type t() :: %__MODULE__{items: [Item.t()], pending: map(), max_size: non_neg_integer()}

  @doc "Create a new work list"
  @spec new(Keyword.t()) :: t()
  def new(opts) do
    %__MODULE__{
      max_size: Keyword.get(opts, :max_size, @default_max_size)
    }
  end

  @doc false
  @spec prepend(t(), [Item.t()], Timestamp.t()) :: t()
  def prepend(work_list, items, now) when is_list(items) do
    updated_items =
      (items ++ work_list.items)
      |> bound_work_items(work_list, now)

    %__MODULE__{work_list | items: updated_items}
  end

  @doc false
  @spec bound_pending_items(map(), t(), Timestamp.t()) :: map()
  def bound_pending_items(pending, work_list, now) do
    if Enum.count(pending) > work_list.max_size do
      # Trim expired pending requests
      kept_pairs =
        Enum.reduce(
          pending,
          [],
          fn {ref, item}, acc ->
            if now > item.expiration do
              [{ref, item} | acc]
            else
              acc
            end
          end
        )

      # If still over maximum, remove the oldest pending request (expiration is smallest)
      if Enum.count(kept_pairs) > work_list.max_size do
        [{ref, item} | newer_pairs] =
          Enum.sort(kept_pairs, fn {_, item1}, {_, item2} ->
            item1.expiration < item2.expiration
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

  @doc false
  @spec bound_work_items([Item.t()], t(), Timestamp.t()) :: [Item.t()]
  def bound_work_items(items, work_list, now) do
    current_size = length(items)

    if current_size <= work_list.max_size do
      items
    else
      Logger.warn(
        "[Jackalope] The worklist exceeds #{work_list.max_size} (#{current_size}). Looking to shrink it."
      )

      {active_items, deleted_count} = remove_expired_work_items(items, now)

      active_size = current_size - deleted_count

      if active_size <= work_list.max_size do
        active_items
      else
        {dropped, cropped_list} = List.pop_at(active_items, active_size - 1)

        Logger.warn("[Jackalope] Dropped #{inspect(dropped)}  from oversized work list")

        cropped_list
      end
    end
  end

  defp remove_expired_work_items(items, now) do
    {list, count} =
      Enum.reduce(
        items,
        {[], 0},
        fn item, {active_list, deleted_count} ->
          if item.expiration >= now,
            do: {[item | active_list], deleted_count},
            else: {active_list, deleted_count + 1}
        end
      )

    {Enum.reverse(list), count}
  end
end

defimpl Jackalope.WorkList, for: Jackalope.TransientWorkList do
  alias Jackalope.TransientWorkList
  require Logger

  @impl Jackalope.WorkList
  def latest_known_state(_work_list) do
    # Transient work lists aren't persisted across restarts, so
    # follow monotonic time. This will result in Jackalope timestamps
    # roughly being the same as `System.monotonic_time/1`. The rough
    # part is that the offset calculation could be a small number of milliseconds
    # off based on how long it takes to get from here to the offset calculation
    # code. That doesn't changing anything, though.
    latest_jackalope_timestamp = System.monotonic_time(:millisecond)
    latest_id = 0

    %{timestamp: latest_jackalope_timestamp, id: latest_id}
  end

  @impl Jackalope.WorkList
  def push(work_list, item, now) do
    updated_items =
      [item | work_list.items]
      |> TransientWorkList.bound_work_items(work_list, now)

    %TransientWorkList{work_list | items: updated_items}
  end

  @impl Jackalope.WorkList
  def peek(work_list) do
    List.first(work_list.items)
  end

  @impl Jackalope.WorkList
  def pop(work_list) do
    %TransientWorkList{work_list | items: tl(work_list.items)}
  end

  @impl Jackalope.WorkList
  def pending(work_list, ref, now) do
    item = hd(work_list.items)

    updated_pending =
      Map.put(work_list.pending, ref, item)
      |> TransientWorkList.bound_pending_items(work_list, now)

    %TransientWorkList{
      work_list
      | items: tl(work_list.items),
        pending: updated_pending
    }
  end

  @impl Jackalope.WorkList
  def reset_pending(work_list) do
    pending_items = Map.values(work_list.pending)

    %{work_list | pending: %{}, items: pending_items ++ work_list.items}
  end

  @impl Jackalope.WorkList
  def done(work_list, ref) do
    {item, pending} = Map.pop(work_list.pending, ref)
    # item can be nil
    {%TransientWorkList{work_list | pending: pending}, item}
  end

  @impl Jackalope.WorkList
  def info(work_list) do
    %{count_waiting: length(work_list.items), count_pending: Enum.count(work_list.pending)}
  end

  @impl Jackalope.WorkList
  def remove_all(work_list) do
    %TransientWorkList{work_list | items: [], pending: %{}}
  end

  @impl Jackalope.WorkList
  def sync(work_list, _now) do
    work_list
  end
end
