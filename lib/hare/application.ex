defmodule Hare.Application do
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

    # Supervision strategy is rest for one, as a crash in Hare would
    # result in inconsistent state in Hare; we would not be able to
    # know about the subscription state; so we teardown the tortoise
    # if Hare crash. Should the Hare.Supervisor crash, Hare should
    # resubscribe to the topic filters it currently know about, so
    # that should be okay.
    opts = [strategy: :rest_for_one, name: Hare.TopSupervisor]
    Supervisor.start_link(children, opts)
  end
end
