defmodule Hare.AppHandler do
  @moduledoc "Behaviour to be implemented by a module in an application using Hare"

  @type client_id :: String.t()

  @callback tortoise_result(client_id, reference(), :ok | {:error, atom}) :: :ok
  @callback subscription(:up | :down, Tortoise.topic_filter()) :: :ok
  @callback message_received(Tortoise.topic_filter(), String.t()) :: :ok
  @callback invalid_payload(Tortoise.topic_filter(), String.t()) :: :ok
end
