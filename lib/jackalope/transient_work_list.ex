defmodule Jackalope.TransientWorkList do
  @moduledoc false

  alias Jackalope.WorkList

  @behaviour WorkList
  require Logger
  @default_max_size 100

  defstruct items: [],
            pending: %{},
            max_size: @default_max_size,
            expiration_fn: nil

  @type t() :: %__MODULE__{items: list(), max_size: non_neg_integer()}

  @impl WorkList
  def new(expiration_fn, _update_expiration_fn, max_size \\ @default_max_size)
      when max_size > 0 do
    %__MODULE__{max_size: max_size, expiration_fn: expiration_fn}
  end

  @impl WorkList
  def push(work_list, item) do
    updated_items =
      [item | work_list.items]
      |> bound_work_items(work_list)

    %__MODULE__{work_list | items: updated_items}
  end

  @impl WorkList
  def peek(work_list) do
    List.first(work_list.items)
  end

  @impl WorkList
  def pop(work_list) do
    %__MODULE__{work_list | items: tl(work_list.items)}
  end

  @impl WorkList
  def pending(work_list, ref) do
    item = hd(work_list.items)

    updated_pending = Map.put(work_list.pending, ref, item) |> bound_pending_items(work_list)

    %__MODULE__{
      work_list
      | items: tl(work_list.items),
        pending: updated_pending
    }
  end

  @impl WorkList
  def reset_pending(work_list) do
    pending_items = Map.values(work_list.pending)

    prepend(%__MODULE__{work_list | pending: %{}}, pending_items)
  end

  @impl WorkList
  def done(work_list, ref) do
    {item, pending} = Map.pop(work_list.pending, ref)
    # item can be nil
    {%__MODULE__{work_list | pending: pending}, item}
  end

  @impl WorkList
  def count(work_list) do
    length(work_list.items)
  end

  @impl WorkList
  def count_pending(work_list) do
    Enum.count(work_list.pending)
  end

  @impl WorkList
  def empty?(work_list) do
    work_list.items == []
  end

  @impl WorkList
  def remove_all(work_list) do
    %__MODULE__{work_list | items: [], pending: %{}}
  end

  defp prepend(work_list, items) when is_list(items) do
    updated_items =
      (items ++ work_list.items)
      |> bound_work_items(work_list)

    %__MODULE__{work_list | items: updated_items}
  end

  # Trim pending as needed to accomodate an additional pending item
  defp bound_pending_items(pending, work_list) do
    if Enum.count(pending) > work_list.max_size do
      # Trim expired pending requests
      kept_pairs =
        Enum.reduce(
          pending,
          [],
          fn {ref, item}, acc ->
            if WorkList.unexpired?(item, work_list.expiration_fn) do
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
            work_list.expiration_fn.(item1) < work_list.expiration_fn.(item2)
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

  defp bound_work_items(items, work_list) do
    current_size = length(items)

    if current_size <= work_list.max_size do
      items
    else
      Logger.warn(
        "[Jackalope] The worklist exceeds #{work_list.max_size} (#{current_size}). Looking to shrink it."
      )

      {active_items, deleted_count} = remove_expired_work_items(items, work_list.expiration_fn)

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

  defp remove_expired_work_items(items, expiration_fn) do
    {list, count} =
      Enum.reduce(
        items,
        {[], 0},
        fn item, {active_list, deleted_count} ->
          if WorkList.unexpired?(item, expiration_fn),
            do: {[item | active_list], deleted_count},
            else: {active_list, deleted_count + 1}
        end
      )

    {Enum.reverse(list), count}
  end
end
