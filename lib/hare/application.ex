defmodule Hare.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      Hare,
      {Hare.Supervisor,
       [
         app_handler: Hare,
         client_id: Hare.client_id(),
         connection_options: Hare.connection_options()
       ]}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Hare.TopSupervisor]
    Supervisor.start_link(children, opts)
  end
end
