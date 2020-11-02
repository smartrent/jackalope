defmodule Hare.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    initial_topics = Application.get_env(:hare, :base_topics, [])

    children = [
      {Hare, [initial_topics: initial_topics]},
      {Hare.Supervisor,
       [
         app_handler: Hare,
         client_id: client_id(),
         connection_options: connection_options()
       ]}
    ]

    # Supervision strategy is rest for one, as a crash in Hare would
    # result in inconsistent state in Hare; we would not be able to
    # know about the subscription state; so we teardown the tortoise
    # if Hare crash. Should the Hare.Supervisor crash, Hare should
    # resubscribe to the topic filters it currently know about, so
    # that should be okay.
    opts = [strategy: :rest_for_one, name: Hare.TopSupervisor]
    Supervisor.start_link(children, opts)
  end

  defp client_id(), do: Application.get_env(:hare, :client_id)

  defp connection_options() do
    [
      server: {
        Tortoise.Transport.Tcp,
        host: mqtt_host(), port: mqtt_port()
      },
      will: %Tortoise.Package.Publish{
        topic: "#{client_id()}/message",
        payload: "last will",
        dup: false,
        qos: 1,
        retain: false
      },
      backoff: [min_interval: 100, max_interval: 30_000]
    ]
  end

  defp mqtt_host(), do: Application.get_env(:hare, :mqtt_host)
  defp mqtt_port(), do: Application.get_env(:hare, :mqtt_port)
end
