defmodule Mocks.Application do
  @moduledoc false

  use Application

  # Every interface, IPv6 included: a private network such as Fly's reaches the mocks over IPv6
  @any {0, 0, 0, 0, 0, 0, 0, 0}

  @impl true
  def start(_type, _args) do
    children =
      [{Task.Supervisor, name: Mocks.Webhooks}, Mocks.Receiver] ++
        if Application.get_env(:mocks, :start_server?, true),
          do: [{Bandit, plug: Mocks.Router, port: Mocks.Settings.port(), ip: @any}],
          else: []

    Supervisor.start_link(children, strategy: :one_for_one, name: Mocks.Supervisor)
  end
end
