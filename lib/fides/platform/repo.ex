defmodule Fides.Platform.Repo do
  use AshPostgres.Repo,
    otp_app: :fides

  @impl true
  def installed_extensions do
    ["ash-functions", "citext", Fides.Platform.PostgresExtension]
  end

  # PostgreSQL 18 brings the native uuidv7() used as the default of every id column.
  @impl true
  def min_pg_version do
    %Version{major: 18, minor: 0, patch: 0}
  end

  # Both must be true: an action that runs without a transaction never reaches
  # on_transaction_begin/1, so its audited writes would fail closed.
  @impl true
  def prefer_transaction?, do: true

  @impl true
  def prefer_transaction_for_atomic_updates?, do: true

  @impl true
  def use_timestamptz?, do: true

  @impl true
  def on_transaction_begin(reason) do
    Fides.Platform.AuditContext.begin_transaction(__MODULE__, reason)
  end
end
