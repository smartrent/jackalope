defmodule Jackalope.MixProject do
  use Mix.Project

  @version "0.7.0"
  @source_url "https://github.com/smartrent/jackalope"

  def project() do
    [
      app: :jackalope,
      version: @version,
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      dialyzer: dialyzer(),
      docs: docs(),
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env()),
      preferred_cli_env: %{
        docs: :docs,
        "hex.publish": :docs,
        "hex.build": :docs
      }
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application() do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps() do
    [
      {:tortoise311, "~> 0.11.0"},
      # {:tortoise311, git: "git@github.com:smartrent/tortoise311.git", branch: "main"},
      {:dialyxir, "~> 1.1.0", only: [:test, :dev], runtime: false},
      {:credo, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.22", only: :docs, runtime: false}
    ]
  end

  defp description() do
    "An opinionated MQTT client library based on Tortoise MQTT"
  end

  defp package() do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp dialyzer() do
    [
      flags: [:race_conditions, :unmatched_returns, :error_handling, :underspecs]
    ]
  end

  defp docs() do
    [
      extras: ["CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
