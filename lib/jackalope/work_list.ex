defmodule Jackalope.WorkList do
  @moduledoc """
  Behaviour for work lists and dispatcher to implementations.
  """

  @type instance() :: any()
  @type item() :: any()
  # A work list is specified by the module implementing it and an instance (the actual list, a GenServer pid)
  @type work_list() :: {module, instance()}
  @type expiration() :: integer | :infinity

  @doc "Create a new instance of a work list"
  @callback new(function(), function(), non_neg_integer()) :: instance()
  @doc "Push an item on the work list"
  @callback push(instance(), any) :: instance()
  @doc "Get the current item on the work list, if any. Leave it on the work list."
  @callback peek(instance()) :: item()
  @doc "Remove the current item from the work list"
  @callback pop(instance()) :: instance()
  @doc "Move a work item to the pending set as it is being worked on, awaiting confirmation of completion."
  @callback pending(instance(), reference()) :: instance()
  @doc "Empty out the set of pending items"
  @callback reset_pending(instance()) :: instance()
  @doc "Remove an item from the pending set"
  @callback done(instance(), reference()) :: {instance(), item()}
  @doc "Count the number of work items"
  @callback count(instance()) :: non_neg_integer()
  @doc "Count the number of pending work items"
  @callback count_pending(instance()) :: non_neg_integer()
  @doc "Are there work items"
  @callback empty?(instance()) :: boolean
  @doc "Remove all work items"
  @callback remove_all(instance()) :: instance()

  @spec now :: integer
  def now(), do: System.monotonic_time(:millisecond)

  @spec unexpired?(any, (any -> expiration)) :: boolean
  def unexpired?(item, expiration_fn), do: not after?(expiration(0), expiration_fn.(item))

  @spec expiration(non_neg_integer | :infinity) :: expiration
  def expiration(:infinity), do: :infinity
  def expiration(ttl), do: now() + ttl

  @doc "Does the first expiration come after the second?"
  @spec after?(expiration, expiration) :: boolean
  def after?(exp1, exp2), do: exp1 > exp2

  @doc "Recalculate an old expiration given the latest time before stop and the earliest time after restart.
  Assumes restart happened soon after stopping."
  @spec rebase_expiration(expiration, integer, integer) :: expiration
  def rebase_expiration(:infinity, _stop_time, _restart_time), do: :infinity

  def rebase_expiration(exp, stop_time, restart_time) do
    delta_now = restart_time - stop_time
    exp + delta_now
  end

  @spec peek(work_list) :: item
  def peek({mod, inst}), do: mod.peek(inst)
  @spec done(work_list, reference()) :: {work_list, item}
  def done({mod, inst}, ref) do
    {inst, item} = mod.done(inst, ref)
    {{mod, inst}, item}
  end

  @spec push(work_list, item) :: work_list
  def push({mod, inst}, item), do: {mod, mod.push(inst, item)}
  @spec reset_pending(work_list) :: work_list
  def reset_pending({mod, inst}), do: {mod, mod.reset_pending(inst)}
  @spec empty?(work_list) :: boolean
  def empty?({mod, inst}), do: mod.empty?(inst)
  @spec pop(work_list) :: work_list
  def pop({mod, inst}), do: {mod, mod.pop(inst)}
  @spec pending(work_list, reference) :: work_list
  def pending({mod, inst}, ref), do: {mod, mod.pending(inst, ref)}
  @spec count(work_list) :: non_neg_integer
  def count({mod, inst}), do: mod.count(inst)
  @spec count_pending(work_list) :: non_neg_integer
  def count_pending({mod, inst}), do: mod.count_pending(inst)

  @spec remove_all(work_list) :: work_list
  def remove_all({mod, inst}), do: {mod, mod.remove_all(inst)}
end
