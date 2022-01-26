defmodule Jackalope do
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  use Supervisor

  require Logger

  @default_mqtt_server {
    Tortoise311.Transport.Tcp,
    host: "localhost", port: 1883
  }

  @default_max_work_list_size 100
  @default_work_list_module Jackalope.TransientWorkList

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
    the client_id of the MQTT connection; see `t Tortoise311.client_id`
    for more information on valid client ids. Notice that the
    client_id needs to be unique on the server, so two clients may not
    have the same client_id.

  - `user_name` (optional) specifies the MQTT Username.

  - `password` (optional) specifies the MQTT Password. Google
    cloud IOT requires a JWT for this field.

  - `initial_topics` (optional) specifies a list of topic_filters
    Jackalope should connect to when a connection has been
    established. Notice that this list is also used should a reconnect
    happen later in the life-cycle. Note that Jackalope does not support
    dynamic subscriptions or unsubscribing. This is the only mechanism
    for subscribing.

  - `handler` (default: `Jackalope.Handler.Logger`) specifies the
    module implementing the callbacks (implementing
    `Jackalope.Handler` behaviour) to use. This module reacts to
    the events Jackalope communicates about the connection
    life-cycle, including receiving a message on a
    subscribed topic filter. Read the documentation for
    `Jackalope.Handler` for more information on the events and
    callbacks.

  - `server` (default: #{inspect(@default_mqtt_server)}) specifies the
    connection type, and its options, to use when connecting to the
    MQTT server. The default specification will attempt to connect to
    a broker running on localhost:1883, on an insecure
    connection. This value should only be used for testing and
    development.

    Server options for use with AWS IoT:

    [
      verify: :verify_peer,
      host: mqtt_host(), # must return the full name, *without wild cards*, for e.g. "abcdefghijklmo-ats.iot.us-east-1.amazonaws.com"
      port: mqtt_port(), # must return the correct port, e.g. 443
      alpn_advertised_protocols: ["x-amzn-mqtt-ca"],
      server_name_indication: to_charlist(mqtt_host()),
      cert: cert, # the device's X509 certificate in DER format
      key: key, # the device's private key in DER format
      cacerts: [signer_cert] ++ aws_ca_certs(), # the device's signer cert, plus AWS IoT CA certs in DER format to be returned by aws_ca_certs()
      versions: [:"tlsv1.2"],
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

  - `work_list_mod` names the module implementing the Jackalope WorkList protocol that will be used to manage
     the publish commands sent to Tortoise by the Jackalope Session.
     The module must also implement the function `@spec new(function(), function(), non_neg_integer(), Keyword.t()) :: any()`.
     See Jackalope.TransientWorkList (the default) for examples.

  - `max_work_list_size` (default: #{@default_max_work_list_size}) specifies the maximum
    number of unexpired work orders Jackalope will retain in its work list
    (the commands yet to be sent to the MQTT server). When the maximum is
    reached, the oldest work order is dropped before adding a new work order.

  - `last_will` (default: nil) specifies the last will message that
    should get published on the MQTT broker if the connection is
    closed or dropped unexpectedly. If we want to specify a last will
    topic we should define a keyword list containing the following:

      - `topic` (Required) the topic to post the last will message to;
        this should be specified as a string and it should be a valid
        MQTT topic; consult `t Tortoise311.topic` for more info on valid
        MQTT topics.

      - `payload` (default: nil) the payload of the last will message;
        notice that we will attempt to JSON encode the payload term
        (unless it is nil), so it will fail if the data fails the JSON
        encode.

      - `qos` (default: 0) either 0 or 1, denoting the quality of
        service the last will message should get published with; note
        that QoS=2 is not supported by AWS IoT.

  - `backoff` (default: [min_interval: 1_000, max_interval: 30_000])
     gives the bounds of an exponential backoff algorithm used when retrying
     from failed connections.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl Supervisor
  def init(opts) do
    client_id = Keyword.get(opts, :client_id, "jackalope")
    jackalope_handler = Keyword.get(opts, :handler, Jackalope.Handler.Logger)
    max_work_list_size = Keyword.get(opts, :max_work_list_size, @default_max_work_list_size)

    work_list_mod = Keyword.get(opts, :work_list_mod, @default_work_list_module)

    children = [
      {Jackalope.Session,
       [
         handler: jackalope_handler,
         max_work_list_size: max_work_list_size,
         work_list_mod: work_list_mod
       ]},
      {Jackalope.Supervisor,
       [
         handler: jackalope_handler,
         client_id: client_id,
         connection_options: connection_options(opts),
         last_will: Keyword.get(opts, :last_will),
         work_list_mod: work_list_mod
       ]}
    ]

    # Supervision strategy is rest for one, as a crash in Jackalope
    # would result in inconsistent state in Jackalope; we would not be
    # able to know about the subscription state; so we teardown the
    # tortoise311 if Jackalope crash. Should the Jackalope.Supervisor
    # crash, Jackalope should resubscribe to the topic filters it
    # currently know about, so that should be okay.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Request the MQTT client to reconnect to the broker

  This can be useful on devices that has multiple network
  interfaces.
  """
  @spec reconnect() :: :ok
  defdelegate reconnect(), to: Jackalope.Session

  @doc """
  Publish a message to the MQTT broker

  The `payload` will get published on `topic`. `Jackalope` will keep
  the message in a queue until we got a connection, at which point it
  will dispatch the publish. This of course present us with a problem:
  what if we place a publish request to "unlock the front door" while
  the client is offline? We don't want to receive a message that the
  front door has been unlocked two hours later when the MQTT client
  reconnect; To solve that problem we have a `ttl` option we can
  specify on the publish.

  ```elixir
  Jackalope.publish("doors/front_door", %{action: "unlock"}, qos: 1, ttl: 5_000)
  ```

  The available publish options are:

    - `qos` (default `1`) sets the quality of service of the message
      delivery; Notice that only quality of service 0 an 1 are
      supported by AWS IoT.

    - `retain` (default `false`) sets whether the broker should retain the message.
      Note that AWS IoT does not support this feature.

    - `ttl` (default `3_600_000`) sets how long (in msecs) publishing the message will be
      retried until it has expired.

  Notice that Jackalope will JSON encode the `payload`; so the data
  should be JSON encodable.
  """
  @spec publish(String.t(), any, options) ::
          :ok | {:error, :invalid_qos}
        when options: [
               {:qos, 0..2} | {:retain, boolean} | {:ttl, non_neg_integer}
             ]
  defdelegate publish(topic, payload, opts \\ []), to: Jackalope.Session

  # TODO Get rid of this stuff
  defp connection_options(opts) do
    server =
      Keyword.get(opts, :server, @default_mqtt_server)
      |> do_configure_server()

    # Default backoff options is 1 sec to 30 secs, doubling each time.
    backoff_opts = Keyword.get(opts, :backoff) || [min_interval: 1_000, max_interval: 30_000]
    Logger.info("[Jackalope] Connecting with backoff options #{inspect(backoff_opts)}")
    initial_topics = Keyword.get(opts, :initial_topics)

    subscriptions =
      for topic_filter <- List.wrap(initial_topics),
          do: {topic_filter, 1}

    [
      server: server,
      backoff: backoff_opts,
      subscriptions: subscriptions
    ]
    |> maybe_add_user_name_password(opts)
  end

  defp maybe_add_user_name_password(connection_options, user_opts) do
    user_name = Keyword.get(user_opts, :user_name)
    password = Keyword.get(user_opts, :password)

    if Enum.any?([user_name, password], &is_nil/1) do
      connection_options
    else
      connection_options
      |> Keyword.put(:user_name, user_name)
      |> Keyword.put(:password, password)
    end
  end

  # Pass normal Tortoise311 transports through as is; assume that the
  # configuration is correct!
  defp do_configure_server({Tortoise311.Transport.Tcp, _opts} = keep), do: keep
  defp do_configure_server({Tortoise311.Transport.SSL, _opts} = keep), do: keep
  # Attempt to create setup a connection that works with AWS IoT
  defp do_configure_server(aws_iot_opts) when is_list(aws_iot_opts) do
    # TODO improve the user experience when working with AWS IoT and
    #   then remove this raise
    raise ArgumentError, "Please specify a Tortoise311 transport for the server"
  end
end
