# Jackalope

[![CircleCI](https://circleci.com/gh/smartrent/jackalope.svg?style=svg)](https://circleci.com/gh/smartrent/jackalope)
[![Hex version](https://img.shields.io/hexpm/v/jackalope.svg "Hex version")](https://hex.pm/packages/jackalope)

<!-- MDOC !-->

`Jackalope` is an opinionated MQTT library that simplifies the use of
[`Tortoise311 MQTT`](https://hex.pm/packages/tortoise311) with cloud IoT
services.

Jackalope aims to make an interface that:

- Ensure that important messages are delivered to the broker, by
  having a local "post office" and tracking the in flight messages,
  and implementing a concept of ttl (time to live) on the messages
  placed in the mailbox; ensuring the "request to unlock the door"
  won't happen two hours later when the MQTT connection finally
  reconnects. This allows Jackalope to accept publish requests while
  the connection is down.

Besides this Jackalope aims to provide helpers for local testing,
allowing you to test your application without having a connection to
AWS; Jackalope should take care of that.

## Usage

The `Jackalope` module implements a `start_link/1` function; use this
to start `Jackalope` as part of your application supervision tree. If
properly supervised it will allow you to start and stop `Jackalope`
with the part the application that needs MQTT connectivity.
`Jackalope` is configured using a keyword list, consult the
`Jackalope.start_link/1` documentation for information on the
available option values.

Once `Jackalope` is running it is possible to publish messages to the broker;
in addition to this there are some connection specific functionality is exposed,
allowing us to ask for the connection status, and request a connection reconnect.

Subscriptions are static only and are set as part of the connection options
provided to Jackalope.

- `Jackalope.publish(topic, payload)` will publish a message to the
  MQTT broker;

- `Jackalope.reconnect()` will disconnect from the broker and
  reconnect; this is useful if the device changes network connection.

Please see the documentation for each of the functions for more
information on usage; publish functions accept options such as setting quality of
service and time to live.

<!-- MDOC !-->

## Configuration

Jackalope puts the publish commands on a work list before it sends them to Tortoise311.
The work list moves the commands from waiting to be sent, to pending (sent and waiting for a response),
to discarded when confirmed by Tortoise311 as processed or when they are expired.

The work list has a maximum size which defaults to 100. Only a maximum number of publish commands
can wait, should Tortoise311 be temporarily disconnected, to be forwarded to Tortoise311.

You can set the Jackalope.start_link/1 `:work_list_mod` option to the desired work list implementation.
See the documentation for module `Jackalope`.

<!-- MDOC !-->

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be
installed by adding `jackalope` to your list of dependencies in
`mix.exs`:

```elixir
def deps do
  [
    {:jackalope, "~> 0.6.0"}
  ]
end
```
