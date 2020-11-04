defmodule Jackalope do
  defdelegate publish(topic, payload, opts \\ []), to: Jackalope.Session

  defdelegate subscribe(topic, opts \\ []), to: Jackalope.Session

  defdelegate unsubscribe(topic, opts \\ []), to: Jackalope.Session
end
