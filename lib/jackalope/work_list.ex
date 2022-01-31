defprotocol Jackalope.WorkList do
  @moduledoc """
  A work list manages work items that have yet to be sent out for processing,
  or have been sent out and are waiting for confirmation of completion.
  """
  @type work_list() :: any()
  @type item() :: any()

  @doc "Push an item on the work list"
  @spec push(work_list(), any) :: work_list()
  def push(work_list, item)
  @doc "Get the current item on the work list, if any. Leave it on the work list."
  @spec peek(work_list()) :: item()
  def peek(work_list)
  @doc "Remove the current item from the work list"
  @spec pop(work_list()) :: work_list()
  def pop(work_list)

  @doc "Move a work item to the pending set as it is being worked on, awaiting confirmation of completion."
  @spec pending(work_list(), reference()) :: work_list()
  def pending(work_list, ref)
  @doc "Empty out the set of pending items"
  @spec reset_pending(work_list()) :: work_list()
  def reset_pending(work_list)
  @doc "Remove an item from the pending set"
  @spec done(work_list(), reference()) :: {work_list(), item()}
  def done(work_list, ref)
  @doc "Info about the work list"
  @spec info(work_list()) :: %{
          required(:count_waiting) => non_neg_integer(),
          required(:count_pending) => non_neg_integer()
        }
  def info(work_list)
  @doc "Remove all work items"
  @spec remove_all(work_list()) :: work_list()
  def remove_all(work_list)
end
