defmodule Fides.DataCase do
  @moduledoc """
  The setup for tests that touch the data layer.

  Each test runs inside the SQL sandbox, which reverts its changes. The whole test
  is a single database transaction, so it gets a single Carbonite transaction: the
  first audited write's meta is the one recorded, and later writes in the same test
  pass under it. Assert fail-closed behaviour before any other audited write.

  Tests start without an audit context, so any write to an audited table fails, as
  in production. Set one with `Fides.Platform.AuditContext.put/1`, or build fixtures
  with `Fides.Factory.insert/1`.
  """

  use ExUnit.CaseTemplate
  use Boundary, check: [in: false, out: false]

  using do
    quote do
      alias Fides.Platform.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Fides.DataCase
    end
  end

  setup tags do
    Fides.DataCase.setup_sandbox(tags)
    on_exit(fn -> Fides.Platform.AuditContext.clear() end)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Fides.Platform.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc "The Carbonite transaction of the current test, or nil."
  def current_carbonite_transaction do
    Carbonite.Query.current_transaction() |> Fides.Platform.Repo.one()
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
