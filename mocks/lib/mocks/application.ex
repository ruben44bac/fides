defmodule Mocks.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [{Task.Supervisor, name: Mocks.Webhooks}] ++
        if Application.get_env(:mocks, :start_server?, true),
          do: [{Bandit, plug: Mocks.Router, port: Mocks.Settings.port()}],
          else: []

    Supervisor.start_link(children, strategy: :one_for_one, name: Mocks.Supervisor)
  end
end
