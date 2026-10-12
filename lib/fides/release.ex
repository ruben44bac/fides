defmodule Fides.Release do
  @moduledoc """
  What a running release can do without Mix: migrate the database, roll a
  migration back and seed the reference data. `bin/migrate` runs `migrate/0` and
  `bin/setup` runs `setup/0`, which is what a fresh environment runs before it
  serves.
  """

  use Boundary,
    deps: [Fides.Countries, Fides.Identity, Fides.Banking, Fides.Accounts, Fides.Risk]

  alias Fides.Accounts
  alias Fides.Banking
  alias Fides.Countries
  alias Fides.Identity
  alias Fides.Risk

  @app :fides

  @doc "Runs every pending migration of every repo."
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Rolls `repo` back to `version`."
  @spec rollback(module(), integer()) :: :ok
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  @doc """
  Seeds the reference data and, where a TOTP seed is configured, the demo staff
  with the first policy version of each country. Running it again leaves the
  same rows, and every write goes through an audited transaction.
  """
  @spec seed() :: :ok
  def seed do
    start_app()

    Countries.Seeds.run()
    Identity.Seeds.run()
    Banking.Seeds.run()

    if Accounts.Demo.enabled?() do
      staff = Accounts.Seeds.run()
      Risk.Seeds.run(staff["risk_manager_1"], staff["risk_manager_2"])
    end

    :ok
  end

  @doc "Migrates, then seeds: what a fresh environment runs before it serves."
  @spec setup() :: :ok
  def setup do
    migrate()
    seed()
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end

  # The seeds go through Ash, so the application must run. A release task never
  # takes jobs: the queues belong to the nodes that serve, and a task that stopped
  # mid-job would leave it orphaned. Nothing serves HTTP either, because only
  # bin/server sets PHX_SERVER.
  defp start_app do
    load_app()

    if not started?(@app) do
      oban = Application.fetch_env!(@app, Oban)
      Application.put_env(@app, Oban, Keyword.merge(oban, queues: false, plugins: false))
      {:ok, _started} = Application.ensure_all_started(@app)
    end

    :ok
  end

  defp started?(app), do: List.keymember?(Application.started_applications(), app, 0)
end
