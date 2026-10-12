defmodule Fides.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  use Boundary, deps: [Fides.Platform, FidesWeb]

  @impl true
  def start(_type, _args) do
    children = [
      FidesWeb.Telemetry,
      Fides.Platform.Repo,
      {DNSCluster, query: Application.get_env(:fides, :dns_cluster_query) || :ignore},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:fides, :ash_domains),
         Application.fetch_env!(:fides, Oban)
       )},
      {Phoenix.PubSub, name: Fides.PubSub},
      # Start to serve requests, typically the last entry
      FidesWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Fides.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FidesWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
