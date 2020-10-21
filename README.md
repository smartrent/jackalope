# Hare

Hare is a sample MQTT application plus utility modules meant to simplify the use of Tortoise.

## MQTT broker

As currently configured, Hare expects an MQTT broker running on localhost via port 1883 with no security.

## Usage

```elixir
Hare.connect()
Hare.subscribe("racing")
Hare.publish("racing", 123)
Hare.unsubscribe("racing")
```

## Using mosquitto sub and pub

mosquitto_sub -h localhost -p 1883 -t #
mosquitto_pub -h localhost -p 1883 -t testing -m 123

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

