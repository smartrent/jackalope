defmodule Jackalope do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    client_id = Keyword.get(opts, :client_id, Application.get_env(:jackalope, :client_id))
    initial_topics = Application.get_env(:jackalope, :base_topics, [])
    jackalope_handler = Application.get_env(:jackalope, :handler, Jackalope.Handler.Logger)

    children = [
      {Jackalope.Session, [initial_topics: initial_topics, handler: jackalope_handler]},
      {Jackalope.Supervisor,
       [
         handler: jackalope_handler,
         client_id: client_id,
         connection_options: connection_options(opts)
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

  defdelegate reconnect(), to: Jackalope.Session

  defdelegate publish(topic, payload, opts \\ []), to: Jackalope.Session

  defdelegate subscribe(topic, opts \\ []), to: Jackalope.Session

  defdelegate unsubscribe(topic, opts \\ []), to: Jackalope.Session

  # TODO Get rid of this stuff
  defp connection_options(opts) do
    mqtt_host = Application.get_env(:jackalope, :mqtt_host)
    mqtt_port = Application.get_env(:jackalope, :mqtt_port)

    [
      server: {
        Tortoise.Transport.Tcp,
        host: mqtt_host, port: mqtt_port
      },
      will: last_will(Keyword.get(opts, :last_will)),
      backoff: [min_interval: 100, max_interval: 30_000]
    ]
  end

  defp last_will(last_will) do
    if last_will do
      %Tortoise.Package.Publish{
        topic: Keyword.fetch!(last_will, :topic),
        payload: Keyword.get(last_will, :payload, nil),
        qos: Keyword.get(last_will, :qos, 0),
        retain: false
      }
    end
  end
end
