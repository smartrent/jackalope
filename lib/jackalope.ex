defmodule Jackalope do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(_opts) do
    initial_topics = Application.get_env(:jackalope, :base_topics, [])
    jackalope_handler = Application.get_env(:jackalope, :handler, Jackalope.Handler.Logger)

    children = [
      {Jackalope.Session, [initial_topics: initial_topics, handler: jackalope_handler]},
      {Jackalope.Supervisor,
       [
         handler: jackalope_handler,
         client_id: client_id(),
         connection_options: connection_options()
       ]}
    ]

    # Supervision strategy is rest for one, as a crash in Jackalope
    # would result in inconsistent state in Jackalope; we would not be
    # able to know about the subscription state; so we teardown the
    # tortoise if Jackalope crash. Should the Jackalope.Supervisor
    # crash, Jackalope should resubscribe to the topic filters it
    # currently know about, so that should be okay.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defdelegate publish(topic, payload, opts \\ []), to: Jackalope.Session

  defdelegate subscribe(topic, opts \\ []), to: Jackalope.Session

  defdelegate unsubscribe(topic, opts \\ []), to: Jackalope.Session

  # TODO Get rid of this stuff
  defp client_id(), do: Application.get_env(:jackalope, :client_id)

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

  defp mqtt_host(), do: Application.get_env(:jackalope, :mqtt_host)
  defp mqtt_port(), do: Application.get_env(:jackalope, :mqtt_port)
end