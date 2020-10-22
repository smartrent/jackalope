# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.
import Config

config :hare,
  client_id: "hare",
  mqtt_host: "localhost",
  mqtt_port: 1883,
  base_topics: ~w(testing)
