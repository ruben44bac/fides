defmodule Fides.Factory do
  @moduledoc """
  Builds test fixtures without leaving evidence. This is the only place where
  Carbonite capture is switched off: everywhere else, writing without an
  audit context fails.
  """

  use Boundary, check: [in: false, out: false]

  alias Fides.Platform.AuditContext
  alias Fides.Platform.Repo

  @doc """
  Runs `fun` with capture switched off for the current transaction, then restores
  each table's own mode. No Carbonite transaction is inserted, so the next audited
  action in the test still records its own meta.
  """
  def insert(fun) when is_function(fun, 0) do
    AuditContext.suppress(fn ->
      :ok = Carbonite.override_mode(Repo, to: :ignore)

      try do
        fun.()
      after
        Repo.query!("SET LOCAL carbonite_default.override_mode TO DEFAULT")
      end
    end)
  end

  @doc "Seeds the six launch countries without evidence."
  def countries do
    insert(&Fides.Countries.Seeds.run/0)
  end
end
