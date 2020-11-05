defmodule Jackalope.MixProject do
  use Mix.Project

  def project do
    [
      app: :jackalope,
      version: "0.1.0",
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [extra_applications: [:logger]]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:tortoise, "~> 0.9"},
      {:jason, "~> 1.1"},
      {:dialyxir, "~> 1.0.0", only: [:test, :dev], runtime: false}
    ]
  end

  defp description do
    "A sample Tortoise client application"
  end

  defp package do
    [
      links: %{"GitHub" => "https://github.com/smartrent/jackalope"}
    ]
  end
end
