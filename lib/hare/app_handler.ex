defmodule Hare.AppHandler do
  @moduledoc "Behaviour to be implemented by applications using the Hare library"

  @type client_id :: String.t()

  @callback connection_status(:up | :down) :: :ok
  @callback tortoise_result(client_id, reference(), :ok | {:error, atom}) :: :ok
  @callback subscription(:up | :down, Tortoise.topic_filter()) :: :ok
  @callback message_received(client_id, Tortoise.topic_filter(), String.t()) :: :ok
  @callback invalid_payload(client_id, Tortoise.topic_filter(), String.t()) :: :ok
end
