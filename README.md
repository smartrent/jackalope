# Hare

Hare is a sample MQTT application plus utility modules meant to
simplify the use of Tortoise connecting to a MQTT server on Amazon
IoT.

Tortoise is a laissez-faire framework for building opinionated MQTT
clients, and Hare is one of them. Technically the MQTT servers running
on AWS IoT implement a subset of the MQTT 3.1.1 specification. Notably
the maximum quality of service allowed on subscriptions and publish
packages are "at least once delivery" (QoS=1), and retained messages
are not allowed. A full [list of differences from the MQTT 3.1.1
protocol is available on the AWS IoT documentation website][mqtt-diff].

[mqtt-diff]: https://docs.aws.amazon.com/iot/latest/developerguide/mqtt.html#mqtt-differences

Hare aims to make an interface that:

- Makes it easy to connect to AWS IoT with the correct encryption
  enabled

- Makes it impossible (or at least hard) to do things that AWS IoT
  does not support; such as publishing a message, or subscribing to a
  topic filter, with a greater quality of service than allowed, or
  publishing a message with the retain flag set

- Ensure that important messages are delivered to the broker, by
  having a local "post office" and tracking the in flight messages

Besides this Hare aims to provide helpers for local testing, allowing
you to test your application without having a connection to AWS; Hare
should take care of that.

## MQTT broker

As currently configured, for local development, Hare expects an MQTT
broker running on localhost via port 1883 with no security.

## Usage

```elixir
# the client should connect automatically when the broker is available
Hare.subscribe("racing")
Hare.publish("racing", 123)
Hare.unsubscribe("racing")
```

## Using mosquitto sub and pub

`mosquitto_sub -h localhost -p 1883 -t #`
`mosquitto_pub -h localhost -p 1883 -t testing -m 123`

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `hare` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:hare, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/hare](https://hexdocs.pm/hare).

