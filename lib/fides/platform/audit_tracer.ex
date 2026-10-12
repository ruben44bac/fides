defmodule Fides.Platform.AuditTracer do
  @moduledoc """
  An Ash tracer that keeps the audit trail complete without callers repeating
  themselves:

    * it remembers the tenant of the running action, so the audited transaction
      records the country even when the audit context does not name one;
    * it carries the audit context into the processes Ash starts for concurrent bulk
      work, where the process dictionary would otherwise be empty and every write
      would fail closed.

  Ash reports the tenant of every action, single or bulk, before it opens the
  transaction.
  """

  @behaviour Ash.Tracer

  alias Fides.Platform.AuditContext

  @key {__MODULE__, :tenants}
  @spans [:action, :bulk_create, :bulk_update, :bulk_destroy, :bulk_batch]

  @doc "The tenant of the innermost running action that has one."
  @spec tenant() :: String.t() | nil
  def tenant, do: Enum.find(Process.get(@key, []), &is_binary/1)

  @impl true
  def trace_type?(type), do: type in @spans

  @impl true
  def start_span(_type, _name) do
    Process.put(@key, [nil | Process.get(@key, [])])
    :ok
  end

  @impl true
  def stop_span do
    Process.put(@key, Enum.drop(Process.get(@key, []), 1))
    :ok
  end

  @impl true
  def set_metadata(_type, %{tenant: tenant}) do
    case Process.get(@key, []) do
      [_current | outer] -> Process.put(@key, [tenant | outer])
      [] -> Process.put(@key, [tenant])
    end

    :ok
  end

  def set_metadata(_type, _metadata), do: :ok

  @impl true
  def get_span_context, do: {Process.get(@key, []), AuditContext.for_transfer()}

  @impl true
  def set_span_context({tenants, audit}) do
    Process.put(@key, tenants)
    AuditContext.transfer(audit)
  end

  def set_span_context(_context), do: :ok

  @impl true
  def set_error(_error, _opts), do: :ok

  @impl true
  def set_error(_error), do: :ok

  @impl true
  def set_handled_error(_error, _opts), do: :ok
end
