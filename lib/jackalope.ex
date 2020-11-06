defmodule Jackalope do
  use Supervisor

  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  @default_mqtt_server {
    Tortoise.Transport.Tcp,
    host: "localhost", port: 1883
  }

  @doc """
  Start a Jackalope session

  This will start a supervised group of processes; part of the group
  will keep track of the topic filter subscription state, and hold a
  list of yet to be published messages, as well as the requested
  subscription changes; the other part of the process tree will keep
  the MQTT connection specific parts, making sure we got a
  connection. See the main documentation on the `Jackalope` module for
  more information on the process architecture.

  `Jackalope.start_link/1` takes a keyword list containing option
  values, that configure the instance, as an argument. The available
  options and their defaults are:

  - `client_id` (default: "jackalope"), string that will be used as
    the client_id of the MQTT connection; see `t Tortoise.client_id`
    for more information on valid client ids. Notice that the
    client_id needs to be unique on the server, so two clients may not
    have the same client_id.

  - `initial_topics` (optional) specifies a list of topic_filters
    Jackalope should connect to when a connection has been
    established. Notice that this list is only used for the initial
    connect, should a reconnect happen later in the life-cycle, the
    current subscription state tracked by Jackalope will be used.

  - `handler` (default: `Jackalope.Handler.Logger`) specifies the
    module implementing the callbacks (implementing
    `Jackalope.Handler` behaviour) to use. This is where you can
    configure how Jackalope reacts to events in the connection
    life-cycle, including what to do when receiving a message on a
    subscribed topic filter; read the documentation for
    `Jackalope.Handler` for more information on the events and
    callbacks.

  - `server` (default: #{inspect(@default_mqtt_server)}) specifies the
    connection type, and its options, to use when connecting to the
    MQTT server. The default specification will attempt to connect to
    a broker running on localhost:1883, on an unsecure
    connection. This value should only be used for testing and
    development;.

  - `last_will` (default: nil) specifies the last will message that
    should get published on the MQTT broker if the connection is
    closed or dropped unexpectedly. If we want to specify a last will
    topic we should define a keyword list containing the following:

      - `topic` (Required) the topic to post the last will message to;
        this should be specified as a string and it should be a valid
        MQTT topic; consult `t Tortoise.topic` for more info on valid
        MQTT topics.

      - `payload` (default: nil) the payload of the last will message;
        notice that we will attempt to JSON encode the payload term
        (unless it is nil), so it will fail if the data fails the JSON
        encode.

      - `qos` (default: 0) either 0 or 1, denoting the quality of
        service the last will message should get published with; note
        that QoS=2 is not supported by AWS IoT.

  - TODO `backoff` make backoff a configurable value

  """
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    client_id = Keyword.get(opts, :client_id, "jackalope")
    initial_topics = Keyword.get(opts, :initial_topics)
    jackalope_handler = Keyword.get(opts, :handler, Jackalope.Handler.Logger)

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
    server =
      Keyword.get(opts, :server, @default_mqtt_server)
      |> do_configure_server()

    [
      server: server,
      will: last_will(Keyword.get(opts, :last_will)),
      backoff: [min_interval: 100, max_interval: 30_000]
    ]
  end

  defp last_will(last_will) do
    if last_will do
      payload_term = Keyword.get(last_will, :payload, nil)

      %Tortoise.Package.Publish{
        topic: Keyword.fetch!(last_will, :topic),
        payload: encode_last_will_payload(payload_term),
        qos: Keyword.get(last_will, :qos, 0),
        retain: false
      }
    end
  end

  defp encode_last_will_payload(nil), do: nil
  defp encode_last_will_payload(term), do: Jason.encode!(term)

  # Pass normal Tortoise transports through as is; assume that the
  # configuration is correct!
  defp do_configure_server({Tortoise.Transport.Tcp, _opts} = keep), do: keep
  defp do_configure_server({Tortoise.Transport.SSL, _opts} = keep), do: keep
  # Attempt to create setup a connection that works with AWS IoT
  defp do_configure_server(aws_iot_opts) when is_list(aws_iot_opts) do
    # TODO improve the user experience when working with AWS IoT and
    #   then remove this raise
    raise ArgumentError, "Please specify a Tortoise transport for the server"

    # TODO Setup the opts for the SSL transport!
    # opts = aws_iot_opts
    # verify: :verify_peer,
    # versions: [:"tlsv1.2"],

    # host: mqtt_host(),
    # port: mqtt_port(),

    # alpn_advertised_protocols: alpn_advertised_protocols(), ?
    # server_name_indication: server_name_indication(), ?

    # cert: cert,
    # key: key,
    # cacerts: cacerts,

    # partial_chain: &partial_chain/1

    # {Tortoise.Transport.SSL, opts}
  end
end
