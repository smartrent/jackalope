defmodule Jackalope.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/smartrent/jackalope"

  def project do
    [
      app: :jackalope,
      version: @version,
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:tortoise, "~> 0.9"},
      {:jason, "~> 1.1"},
      {:dialyxir, "~> 1.0.0", only: [:test, :dev], runtime: false},
      {:ex_doc, "~> 0.23", only: :dev, runtime: false}
    ]
  end

  defp description do
    "A sample Tortoise client application"
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
