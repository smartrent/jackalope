defmodule Jackalope.Subscriptions do
  @moduledoc false

  # This module tracks topic subscriptions added/removed via `Jackalope.subscribe`
  # and `Jackalope.unsubscribe`. It is used to ensure the correct topics are
  # subscribed to when reconnecting.

  use Agent

  @spec start_link([String.t()]) :: Agent.on_start()
  def start_link(initial_topics) do
    initial_topics = initial_topics |> List.wrap() |> MapSet.new()
    Agent.start_link(fn -> initial_topics end, name: __MODULE__)
  end

  @spec topic_filters() :: [{String.t(), Tortoise311.qos()}]
  def topic_filters(), do: Agent.get(__MODULE__, & &1) |> topic_filters()
  @spec topic_filters([String.t()]) :: [{String.t(), Tortoise311.qos()}]
  def topic_filters(topics), do: Enum.map(topics, &{&1, 1})

  @spec add([String.t()]) :: :ok
  def add(topics) do
    topics = topics |> List.wrap() |> MapSet.new()
    Agent.update(__MODULE__, &MapSet.union(&1, topics))
  end

  @spec remove([String.t()]) :: :ok
  def remove(topics) do
    topics = topics |> List.wrap() |> MapSet.new()
    Agent.update(__MODULE__, &MapSet.difference(&1, topics))
  end
end
