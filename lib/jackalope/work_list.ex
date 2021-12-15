defmodule Jackalope.WorkList do
  @moduledoc false

  require Logger
  @default_max_size 100

  defstruct items: [],
            max_size: @default_max_size

  @type t() :: %__MODULE__{items: list(), max_size: non_neg_integer()}

  @spec new(list(), non_neg_integer()) :: t()
  def new(items, max_size \\ @default_max_size) when max_size > 0 do
    %__MODULE__{items: items, max_size: max_size}
  end

  @spec push(t(), any) :: t()
  def push(work_list, item) do
    updated_items =
      [item | work_list.items]
      |> bound(work_list.max_size)

    %__MODULE__{work_list | items: updated_items}
  end

  @spec prepend(t(), list) :: t()
  def prepend(work_list, items) when is_list(items) do
    updated_items =
      (items ++ work_list.items)
      |> bound(work_list.max_size)

    %__MODULE__{work_list | items: updated_items}
  end

  @spec peek(t()) :: any()
  def peek(work_list) do
    List.first(work_list.items)
  end

  @spec pop(t()) :: t()
  def pop(work_list) do
    %__MODULE__{work_list | items: tl(work_list.items)}
  end

  @spec count(t()) :: non_neg_integer()
  def count(work_list) do
    length(work_list.items)
  end

  @spec empty?(t()) :: boolean
  def empty?(work_list) do
    work_list.items == []
  end

  @spec expiration(integer) :: integer
  def expiration(ttl), do: System.monotonic_time(:millisecond) + ttl

  defp bound(items, max_size) do
    current_size = length(items)

    if current_size <= max_size do
      items
    else
      Logger.warn(
        "[Jackalope] The worklist exceeds #{max_size} (#{current_size}). Looking to shrink it."
      )

      {active_items, deleted_count} = gc(items)

      active_size = current_size - deleted_count

      if active_size <= max_size do
        active_items
      else
        {dropped, cropped_list} = List.pop_at(active_items, active_size - 1)

        Logger.warn("[Jackalope] Dropped #{inspect(dropped)}  from oversized work list")

        cropped_list
      end
    end
  end

  defp gc(items) do
    now = expiration(0)

    {list, count} =
      Enum.reduce(
        items,
        {[], 0},
        fn {_cmd, opts} = item, {active_list, deleted_count} ->
          expiration = Keyword.fetch!(opts, :expiration)

          if expiration > now,
            do: {[item | active_list], deleted_count},
            else: {active_list, deleted_count + 1}
        end
      )

    {Enum.reverse(list), count}
  end
end
