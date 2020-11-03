defmodule Jackalope.Supervisor do
  @moduledoc "A supervisor for all things MQTT"

  use Supervisor
  require Logger
  alias Jackalope.{Watchdog, TortoiseClient}

  @type init_arg ::
          {:app_handler, module()} | {:client_id, atom()} | {:connection_options, Keyword.t()}

  @spec start_link([init_arg()]) :: Supervisor.on_start()
  def start_link(init_args \\ []) do
    Supervisor.start_link(__MODULE__, init_args, name: __MODULE__)
  end

  def init(init_args) do
    Logger.info("[Jackalope] Starting supervisor")

    children = [
      # The Tortoise connection supervisor
      {DynamicSupervisor, strategy: :one_for_one, name: ConnectionSupervisor},
      # The Tortoise client
      {TortoiseClient, init_args},
      # The Tortoise Connection watchdog - crashes if Tortoise has become unresponsive
      {Watchdog, init_args}
    ]

    # One goes, everyone goes
    opts = [strategy: :one_for_all]
    Supervisor.init(children, opts)
  end
end
