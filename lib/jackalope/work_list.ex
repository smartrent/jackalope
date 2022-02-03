defprotocol Jackalope.WorkList do
  @moduledoc """
  A work list manages work items that have yet to be sent out for processing,
  or have been sent out and are waiting for confirmation of completion.
  """
  alias Jackalope.Item
  alias Jackalope.Timestamp

  @type work_list() :: struct()

  @doc """
  Read the latest Jackalope timestamp that was used
  """
  @spec latest_known_state(work_list()) :: %{timestamp: Timestamp.t(), id: non_neg_integer()}
  def latest_known_state(work_list)

  @doc "Push an item on the work list"
  @spec push(work_list(), Item.t(), Timestamp.t()) :: work_list()
  def push(work_list, item, now)
  @doc "Get the current item on the work list, if any. Leave it on the work list."
  @spec peek(work_list()) :: Item.t() | nil
  def peek(work_list)
  @doc "Remove the current item from the work list"
  @spec pop(work_list()) :: work_list()
  def pop(work_list)

  @doc """
  Sync the state of the work list with anything that backs it

  This function is called periodically and if Jackalope is terminating so that
  the work list implementation can try to get as much as possible recorded
  for an unexpected or expected restart.
  """
  @spec sync(work_list(), Timestamp.t()) :: work_list()
  def sync(work_list, now)

  @doc "Move a work item to the pending set as it is being worked on, awaiting confirmation of completion."
  @spec pending(work_list(), reference(), Timestamp.t()) :: work_list()
  def pending(work_list, ref, now)
  @doc "Empty out the set of pending items"
  @spec reset_pending(work_list()) :: work_list()
  def reset_pending(work_list)
  @doc "Remove an item from the pending set"
  @spec done(work_list(), reference()) :: {work_list(), Item.t() | nil}
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
