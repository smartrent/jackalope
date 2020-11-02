defmodule Hare.AppHandler do
  @moduledoc """
  Behaviour to be implemented by a module in an application using Hare
  """

  @callback message_received(Tortoise.topic_filter(), String.t()) :: :ok
  @callback invalid_payload(Tortoise.topic_filter(), String.t()) :: :ok
end
