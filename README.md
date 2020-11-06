# Jackalope

<!-- MDOC !--> 

`Jackalope` is a sample MQTT application plus utility modules meant to
simplify the use of Tortoise connecting to a MQTT server on Amazon
IoT.

`Tortoise` is a laissez-faire framework for building opinionated MQTT
clients, and Jackalope is one of them. Technically the MQTT servers
running on AWS IoT implement a subset of the MQTT 3.1.1
specification. Notably the maximum quality of service allowed on
subscriptions and publish packages are "at least once delivery"
(QoS=1), and retained messages are not allowed. A full [list of
differences from the MQTT 3.1.1 protocol is available on the AWS IoT
documentation website][mqtt-diff].

[mqtt-diff]: https://docs.aws.amazon.com/iot/latest/developerguide/mqtt.html#mqtt-differences

Jackalope aims to make an interface that:

- Makes it easy to connect to AWS IoT with the correct encryption
  enabled

- Makes it impossible (or at least hard) to do things that AWS IoT
  does not support; such as publishing a message, or subscribing to a
  topic filter, with a greater quality of service than allowed, or
  publishing a message with the retain flag set

- Ensure that important messages are delivered to the broker, by
  having a local "post office" and tracking the in flight messages,
  and implementing a concept of ttl (time to live) on the messages
  placed in the mailbox; ensuring the "request to unlock the door"
  won't happen two hours later when the MQTT connection finally
  reconnects. This allows Jackalope to accept publish and subscription
  requests while the connection is down.

Besides this Jackalope aims to provide helpers for local testing,
allowing you to test your application without having a connection to
AWS; Jackalope should take care of that.

## Usage

The `Jackalope` module implements a `start_link/1` function; use this
to start `Jackalope` as part of your application supervision tree. If
properly supervised it will allow you to start and stop `Jackalope`
with the part the application that needs MQTT
connectivity. `Jackalope` is configured using a keyword list, consult
the `Jackalope.start_link/1` documentation for information on the
available option values.

Once `Jackalope` is running it is possible to subscribe, unsubscribe,
and publish messages to the broker; in addition to this there are some
connection specific functionality is exposed, allowing us to ask for
the connection status, and request a connection reconnect.

- `Jackalope.subscribe(topic)` request a subscription to a specific
  topic. The topic will be added to the list of topics `Jackalope`
  will ensure we are subscribed to.
  
- `Jackalope.unsubscribe(topic)` will request an unsubscribe from a
  specific topic and remove the topic from the list of topics
  `Jackalope` ensure are subscribed to.
  
- `Jackalope.publish(topic, payload)` will publish a message to the
  MQTT broker; 

- `Jackalope.reconnect()` will disconnect from the broker and
  reconnect; this is useful if the device changes network connection.

Please see the documentation for each of the functions for more
information on usage; especially the subscribe and publish functions
accepts options such as setting quality of service and time to live.

<!-- MDOC !-->

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be
installed by adding `jackalope` to your list of dependencies in
`mix.exs`:

```elixir
def deps do
  [
    {:jackalope, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with
[ExDoc](https://github.com/elixir-lang/ex_doc) and published on
[HexDocs](https://hexdocs.pm). Once published, the docs can be found
at [https://hexdocs.pm/jackalope](https://hexdocs.pm/jackalope).

