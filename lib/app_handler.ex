defmodule Hare.AppHandler do
  @moduledoc "Behaviour to be implemented by applications using the Hare library"

  @type client_id :: atom()
  @type connection_options :: Keyword.t()

  @callback tortoise_connection_options() :: connection_options()
  @callback client_id() :: atom()
  @callback connection_status(:up | :down) :: :ok
  @callback tortoise_result(client_id, reference(), :ok | {:error, atom}) :: :ok
  @callback subscription(:up | :down, Tortoise.topic_filter()) :: :ok
  @callback message_received(client_id, Tortoise.topic_filter(), String.t()) :: :ok
  @callback invalid_payload(client_id, Tortoise.topic_filter(), String.t()) :: :ok
end
