defmodule Jackalope.WorkList.Expiration do
  @moduledoc """
  Common functions for work lists.
  """
  @type expiration() :: non_neg_integer() | :infinity

  @spec now :: integer
  def now(), do: System.monotonic_time(:millisecond)

  @spec unexpired?(any, (any -> expiration)) :: boolean
  def unexpired?(item, expiration_fn), do: not after?(expiration(0), expiration_fn.(item))

  @spec expiration(non_neg_integer | :infinity) :: expiration
  def expiration(:infinity), do: :infinity
  def expiration(ttl) when is_integer(ttl), do: now() + ttl

  @doc "Does the first expiration come after the second?"
  @spec after?(expiration, expiration) :: boolean
  def after?(exp1, exp2), do: exp1 > exp2

  @doc "Recalculate an old expiration given the latest time before stop and the earliest time after restart.
  Assumes restart happened soon after stopping."
  @spec rebase_expiration(expiration, integer, integer) :: expiration
  def rebase_expiration(:infinity, _stop_time, _restart_time), do: :infinity

  def rebase_expiration(exp, stop_time, restart_time) do
    delta_now = restart_time - stop_time
    floor(exp + delta_now)
  end
end
