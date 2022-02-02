defmodule Jackalope.Persistent.State do
  defstruct [:jack_time_offset, :oldest_index, :next_index]

  @type t() :: %__MODULE__{
          jack_time_offset: integer(),
          oldest_index: integer(),
          next_index: integer()
        }
end
