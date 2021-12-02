defmodule Jackalope.Supervisor do
  @moduledoc false

  # Supervisor for the MQTT connection specific processes

  use Supervisor
  require Logger
  alias Jackalope.TortoiseClient

  @type init_arg ::
          {:app_handler, module()} | {:client_id, atom()} | {:connection_options, Keyword.t()}

  @spec start_link([init_arg()]) :: Supervisor.on_start()
  def start_link(init_args \\ []) do
    Supervisor.start_link(__MODULE__, init_args, name: __MODULE__)
  end

  @impl Supervisor
  def init(init_args) do
    children = [
      # The Tortoise311 connection supervisor
      {DynamicSupervisor, strategy: :one_for_one, name: ConnectionSupervisor},
      # The Tortoise311 client
      {TortoiseClient, init_args}
    ]

    # One goes, everyone goes
    opts = [strategy: :one_for_all]
    Supervisor.init(children, opts)
  end
end
