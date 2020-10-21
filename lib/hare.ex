defmodule Hare do
  @moduledoc "MQTT application logic"

  use GenServer

  @behaviour Hare.AppHandler
  require Logger
  alias Hare.TortoiseClient

  @qos 1

  defmodule State do
    defstruct connection_status: nil,
              failed_messages: [],
              pending_messages: %{},
              pending_subscriptions: %{},
              pending_unsubscriptions: %{},
              subscriptions: [],
              failed_subscriptions: [],
              failed_unsubscriptions: []
  end

  @spec client_id() :: String.t()
  def client_id(), do: Application.get_env(:hare, :client_id)

  @spec connection_options() :: Keyword.t()
  def connection_options() do
    [
      server: {
        Tortoise.Transport.Tcp,
        host: mqtt_host(), port: mqtt_port()
      },
      user_name: mqtt_user_name(),
      password: mqtt_password(),
      will: %Tortoise.Package.Publish{
        topic: "#{client_id()}/message",
        payload: "{\"code\": \"going_down\",\"msg\": \"Last will message\"}",
        dup: false,
        qos: @qos,
        retain: false
      },
      # Subcriptions are set after all devices inclusions are recovered
      subscriptions: base_topics(),
      backoff: [min_interval: 100, max_interval: 30_000]
    ]
  end

  @doc "Publish an MQTT message"
  @spec publish_message([Tortoise.topic()], map()) :: :ok
  def publish_message(topic, payload) do
    GenServer.cast(__MODULE__, {:publish, topic, payload})
  end

  def start_link(_) do
    Logger.info("[Hare] Starting #{inspect(__MODULE__)}...")
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  ### AppHandler callbacks

  @impl true
  def connection_status(status) do
    GenServer.cast(__MODULE__, {:connection_status, status})
  end

  @impl true
  def tortoise_result(client_id, reference, result) do
    Logger.info(
      "[Hare] Tortoise result for client #{inspect(client_id)} referenced by #{inspect(reference)} is #{
        inspect(result)
      }"
    )

    GenServer.cast(__MODULE__, {:tortoise_result, client_id, reference, result})
  end

  @impl true
  def subscription(status, topic) do
    Logger.info("[Hare] Requested subscription #{inspect(status)} for topic #{inspect(topic)}")
    :ok
  end

  @impl true
  def message_received(client_id, topic, payload) do
    Logger.info(
      "[Hare] Tortoise received message with topic #{inspect(topic)} and payload #{
        inspect(payload)
      } for client #{inspect(client_id)}"
    )

    :ok
  end

  @impl true
  def invalid_payload(client_id, topic, payload) do
    Logger.info(
      "[Hare] Tortoise received an invalid message with topic #{inspect(topic)} and payload #{
        inspect(payload)
      } for client #{inspect(client_id)}"
    )

    :ok
  end

  ### GenServer callbacks

  @impl true
  def init(_) do
    {:ok, %State{}}
  end

  @impl true
  def handle_cast({:connection_status, connection_status}, state) do
    {:noreply, %State{state | connection_status: connection_status}}
  end

  def handle_cast({:publish, topic, payload}, state) do
    {:noreply, publish_mqtt_message(topic, payload, state)}
  end

  def handle_cast(
        {:tortoise_result, _client_id, reference, result},
        %State{
          pending_messages: pending_messages,
          pending_subscriptions: pending_subscriptions,
          pending_unsubscriptions: pending_unsubscriptions
        } = state
      ) do
    updated_state =
      cond do
        Map.get(pending_messages, reference) != nil ->
          process_publishing_result(reference, result, state)

        Map.get(pending_subscriptions, reference) != nil ->
          process_subscription_result(reference, result, state)

        Map.get(pending_unsubscriptions, reference) != nil ->
          process_unsubscription_result(reference, result, state)

        true ->
          Logger.warn("[Hubbub] Ignoring unknown Tortoise result reference #{inspect(reference)}")
          state
      end

    {:noreply, updated_state}
  end

  ### PRIVATE

  defp publish_mqtt_message(
         topic,
         payload,
         %State{
           failed_messages: failed_messages,
           pending_messages: pending_messages
         } = state
       ) do
    updated_state = retry_failed(state)

    case do_publish_message(topic, payload, client_id()) do
      :ok ->
        state

      {:ok, reference} ->
        Logger.debug(
          "[Hare] Asked Tortoise to publish #{inspect(topic)} with #{inspect(payload)}. Got #{
            inspect(reference)
          }."
        )

        %State{
          updated_state
          | pending_messages:
              Map.put(pending_messages, reference, %{topic: topic, payload: payload})
        }

      {:error, reason} ->
        Logger.warn(
          "[Hare] Asked Tortoise to publish #{inspect(topic)} with #{inspect(payload)}. Got error #{
            inspect(reason)
          }."
        )

        {:noreply,
         %State{
           updated_state
           | failed_messages: [%{topic: topic, payload: payload} | failed_messages]
         }}
    end
  end

  defp mqtt_subscribe(
         topic,
         %State{
           pending_subscriptions: pending_subscriptions,
           failed_subscriptions: failed_subscriptions
         } = state
       ) do
    updated_state = retry_failed(state)

    case TortoiseClient.subscribe(topic) do
      {:ok, reference} ->
        %State{
          updated_state
          | pending_subscriptions: Map.put(pending_subscriptions, reference, topic)
        }

      {:error, _reason} ->
        %State{
          updated_state
          | failed_subscriptions: [topic | failed_subscriptions]
        }
    end
  end

  defp mqtt_unsubscribe(
         topic,
         %State{
           pending_unsubscriptions: pending_unsubscriptions,
           failed_unsubscriptions: failed_unsubscriptions
         } = state
       ) do
    updated_state = retry_failed(state)

    case TortoiseClient.unsubscribe(topic) do
      {:ok, reference} ->
        %State{
          updated_state
          | pending_unsubscriptions: Map.put(pending_unsubscriptions, reference, topic)
        }

      {:error, _reason} ->
        %State{
          updated_state
          | failed_unsubscriptions: [topic | failed_unsubscriptions]
        }
    end
  end

  defp do_publish_message(topic, payload, client_id) do
    topic =
      [client_id | topic]
      |> Enum.join("/")

    TortoiseClient.publish(topic, payload)
  end

  defp retry_failed(state) do
    state
    |> republish_failed()
    |> resubscribe_failed()
    |> reunsubscribe_failed()
  end

  # Returns updated state
  defp republish_failed(%State{failed_messages: failed_messages} = state) do
    Enum.reduce(
      Enum.reverse(failed_messages),
      %State{state | failed_messages: []},
      fn %{topic: topic, payload: payload} = message, acc ->
        Logger.info("[Hare] Republishing failed message #{inspect(message)}")

        publish_mqtt_message(topic, payload, acc)
      end
    )
  end

  # Returns updated state
  defp resubscribe_failed(%State{failed_subscriptions: failed_subscriptions} = state) do
    Enum.reduce(
      failed_subscriptions,
      %State{state | failed_subscriptions: []},
      fn topic, acc ->
        Logger.info("[Hubbub] Retrying failed subscription #{inspect(topic)}")

        mqtt_subscribe(topic, acc)
      end
    )
  end

  # Returns updated state
  defp reunsubscribe_failed(%State{failed_unsubscriptions: failed_unsubscriptions} = state) do
    Enum.reduce(
      failed_unsubscriptions,
      %State{state | failed_unsubscriptions: []},
      fn topic, acc ->
        Logger.info("[Hare] Retrying failed unsubscription #{inspect(topic)}")

        mqtt_unsubscribe(topic, acc)
      end
    )
  end

  # Returns updated state
  defp process_publishing_result(
         reference,
         result,
         %State{pending_messages: pending_messages, failed_messages: failed_messages} = state
       ) do
    message = Map.fetch!(pending_messages, reference)
    updated_pending_messages = Map.delete(pending_messages, reference)

    case result do
      :ok ->
        Logger.info("[Hare] Message #{inspect(message)} successfully published")

        %State{state | pending_messages: updated_pending_messages}

      {:error, reason} ->
        Logger.warn("[Hare] Failed to publish #{inspect(message)}: #{inspect(reason)}")

        %State{
          state
          | pending_messages: updated_pending_messages,
            failed_messages: [message | failed_messages]
        }
    end
  end

  # Returns updated state
  defp process_subscription_result(
         reference,
         result,
         %State{
           pending_subscriptions: pending_subscriptions,
           subscriptions: subscriptions,
           failed_subscriptions: failed_subscriptions
         } = state
       ) do
    topic = Map.fetch!(pending_subscriptions, reference)
    updated_pending_subscriptions = Map.delete(pending_subscriptions, reference)

    case result do
      :ok ->
        Logger.info("[Hare] Subscription to #{inspect(topic)} successful")

        %State{
          state
          | pending_subscriptions: updated_pending_subscriptions,
            subscriptions: Enum.uniq([topic | subscriptions]),
            failed_subscriptions: List.delete(failed_subscriptions, topic)
        }

      {:error, reason} ->
        Logger.warn("[Hare] Subscription to #{inspect(topic)} failed: #{inspect(reason)}")

        %State{
          state
          | pending_subscriptions: updated_pending_subscriptions,
            failed_subscriptions: Enum.uniq([topic | failed_subscriptions])
        }
    end
  end

  # Returns updated state
  defp process_unsubscription_result(
         reference,
         result,
         %State{
           pending_unsubscriptions: pending_unsubscriptions,
           subscriptions: subscriptions,
           failed_unsubscriptions: failed_unsubscriptions
         } = state
       ) do
    topic = Map.fetch!(pending_unsubscriptions, reference)
    updated_pending_unsubscriptions = Map.delete(pending_unsubscriptions, reference)

    case result do
      :ok ->
        Logger.info("[Hare] Unsubscription to #{inspect(topic)} successful")

        %State{
          state
          | pending_unsubscriptions: updated_pending_unsubscriptions,
            subscriptions: List.delete(subscriptions, topic),
            failed_unsubscriptions: List.delete(failed_unsubscriptions, topic)
        }

      {:error, reason} ->
        Logger.warn("[Hare] Unsubscription to #{inspect(topic)} failed: #{inspect(reason)}")

        %State{
          state
          | pending_unsubscriptions: updated_pending_unsubscriptions,
            failed_unsubscriptions: Enum.uniq([topic | failed_unsubscriptions])
        }
    end
  end

  defp base_topics(), do: []

  defp mqtt_host(), do: Application.get_env(:hare, :mqtt_host)
  defp mqtt_port(), do: Application.get_env(:hare, :mqtt_port)
  defp mqtt_user_name(), do: Application.get_env(:hare, :mqtt_user_name)
  defp mqtt_password(), do: Application.get_env(:hare, :mqtt_password)
end
