defmodule Jackalope.MixProject do
  use Mix.Project

  @version "0.9.0"
  @source_url "https://github.com/smartrent/jackalope"

  def project() do
    [
      app: :jackalope,
      version: @version,
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      dialyzer: dialyzer(),
      docs: docs(),
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def cli do
    [preferred_envs: %{docs: :docs, "hex.publish": :docs, "hex.build": :docs}]
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
      # {:tortoise311, "~> 0.12"},
      {:tortoise311, git: "git@github.com:smartrent/tortoise311.git", branch: "test_all"},
      {:dialyxir, "~> 1.4", only: [:test, :dev], runtime: false},
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
      flags: [:unmatched_returns, :error_handling, :missing_return, :extra_return, :underspecs]
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
