# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
use Mix.Config

config :jackalope, :data_dir, "tmp"

# Import a test config if available
if Mix.env() == :test and File.exists?("config/test.exs") do
  import_config "test.exs"
end

# Import a dev config if available
if Mix.env() == :dev and File.exists?("config/dev.exs") do
  import_config "dev.exs"
end

# Import a prod config if available
if Mix.env() == :prod and File.exists?("config/prod.exs") do
  import_config "prod.exs"
end
