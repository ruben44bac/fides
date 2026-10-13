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
      # Sweeps expired tokens
      {AshAuthentication.Supervisor, otp_app: :fides},
      {DNSCluster, query: Application.get_env(:fides, :dns_cluster_query) || :ignore},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:fides, :ash_domains),
         oban_config(
           Application.get_env(:fides, :role, "all"),
           Application.fetch_env!(:fides, Oban)
         )
       )},
      {Phoenix.PubSub, name: Fides.PubSub},
      # Tells the screens of this node about every change to an application
      Fides.Platform.ChangeListener,
      # Start to serve requests, typically the last entry
      FidesWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Fides.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Oban as the node's role wants it: a web node only enqueues jobs, so it runs no
  queue and no plugin; a worker, or a node that does both, runs them all.
  """
  @spec oban_config(String.t(), keyword()) :: keyword()
  def oban_config("web", config), do: Keyword.merge(config, queues: false, plugins: false)
  def oban_config(_worker_or_all, config), do: config

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FidesWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
