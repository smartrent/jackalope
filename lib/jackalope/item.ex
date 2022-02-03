defmodule Jackalope.Item do
  @moduledoc false

  @typedoc """
  An allowed Tortoise option
  """
  @type option() :: {:qos, 0..2}

  # This holds one item that will be sent up to the MQTT broker
  #
  # * `:id` - a unique ID for this item
  # * `:topic` - MQTT topic
  # * `:payload` - MQTT payload
  # * `:expiration` - The expiration for this item in Jackalope time
  # * `:options` - a keyword list of Tortoise publish options
  defstruct [:id, :expiration, :topic, :payload, :options]

  @type t() :: %__MODULE__{
          id: non_neg_integer(),
          expiration: integer(),
          topic: String.t(),
          payload: binary(),
          options: [option()]
        }
end
