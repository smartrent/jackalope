defmodule Jackalope.Timestamp do
  @moduledoc """
  Utilities for working with Jackalope times

  Jackalope time is monotonic time with a monotonically increasing base offset
  that can be preserved across restarts. This means that timestamps can be
  compared between boots unlike those returned by `System.monotonic_time/0`. To
  take advantage of this, persistance must be enabled so that Jackalope's recovery
  routines can figure out where Jackalope timestamps should start.

  While a device is off, there's no attempt to adjust the time. This means that
  if a user specifies a 30 minute expiration on an item and the device turns off
  at the 10 minute mark. When the device turns back on and Jackalope is running
  again, that item will have 20 minutes more to complete. Whether the device has
  been off for a second or a day doesn't matter. If this is an issue, the item
  that's being sent should include a UTC or local timestamp so that the message
  can be discarded elsewhere.

  Why?

  1. One of the goals of Jackalope is to persist important messages in case
     of a reboot. Some timestamp is needed to determine when those messages
     no longer need to be sent up.
  2. `System.monotonic_time/0` has no expectations for monotonicity across
     reboots.
  3. `System.os_time/0` can't be used due to time warps, time zone changes,
     etc. for tracking expirations.
  4. Any kind of absolute time is tough to have on devices without real-time
     clocks unless you specifically wait until NTP has had a chance to
     synchronize, and who knows when that will happen.
  """

  # Arbitrarily define infinity to be 7 days long
  @infinity_expiration 7 * 86400 * 1000

  # Arbitrarily advance Jackalope timestamps by a minute if there's a restart
  # This guarantees forward advancement of Jackalope timestamps even in the
  # face of restarts.
  @restart_penalty 60000

  @typedoc """
  A Jackalope timestamp. These are in milliseconds
  """
  @type t() :: integer()

  @doc """
  Calculate the Jackalope time offset from monotonic time

  The offset is good until the Erlang VM restarts.

  * `latest_jackalope_timestamp` is the latest known Jackalope time in existence (on this device)
  * `penalty` is the amount of milliseconds that should be added to penalize the device for
    restarting
  """
  @spec calculate_offset(t()) :: integer()
  def calculate_offset(latest_jackalope_timestamp) do
    latest_jackalope_timestamp - System.monotonic_time(:millisecond) + @restart_penalty
  end

  @doc """
  Return the current Jackalope timestamp

  Pass the `offset` calculated by `calculate_offset/3`.
  """
  @spec now(integer()) :: t()
  def now(offset) do
    System.monotonic_time(:millisecond) + offset
  end

  @doc """
  Calculate the expiration time in Jackalope time

  This function makes expiration times in the past expire immediately and caps
  expiration times to an arbitrary "infinite" duration.
  """
  @spec ttl_to_expiration(t(), integer() | :infinity) :: t()
  def ttl_to_expiration(jackalope_timestamp, ttl) when ttl >= 0 and ttl < @infinity_expiration,
    do: jackalope_timestamp + ttl

  def ttl_to_expiration(jackalope_timestamp, ttl) when ttl < 0, do: jackalope_timestamp

  def ttl_to_expiration(jackalope_timestamp, _infinity),
    do: jackalope_timestamp + @infinity_expiration
end
