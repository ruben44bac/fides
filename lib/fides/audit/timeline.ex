defmodule Fides.Audit.Timeline do
  @moduledoc """
  An application's story, from Carbonite's transactions and changes: the
  application's own row, and the rows of its evidence that name it in
  `application_id`. Each entry is one transaction, with its meta and what it changed.

  Of every row only public and financial columns are kept, so nothing personal leaves
  the evidence. Where a row changed, its earlier values are those of its previous
  change in the story.
  """

  import Ecto.Query

  alias Carbonite.Change
  alias Carbonite.Transaction
  alias Fides.Platform.Repo

  @prefix "carbonite_default"

  # The tables that tell an application's story, with the columns worth showing of each
  @columns %{
    "credit_applications" => ~w(state revision lock_version policy_version_id channel),
    "application_revisions" => ~w(number amount_minor monthly_income_minor cause),
    "bank_profiles" => ~w(origin score observed_income_minor total_debt_minor income_months),
    "decision_records" => ~w(outcome reason_codes cause),
    "case_facts" => ~w(name agent tool),
    "notifications" => ~w(template channel state language)
  }

  @typedoc "One row written: the table, the operation, and the columns shown before and after."
  @type change :: %{
          table: String.t(),
          op: :insert | :update | :delete,
          changed: [String.t()],
          data: map(),
          before: map()
        }

  @typedoc "One transaction: when, who, why, and the rows it wrote."
  @type entry :: %{
          id: integer(),
          at: DateTime.t(),
          actor: String.t() | nil,
          reason: String.t() | nil,
          action: String.t() | nil,
          country: String.t() | nil,
          correlation_id: String.t() | nil,
          changes: [change()]
        }

  @spec build(Ecto.UUID.t()) :: [entry()]
  def build(application_id), do: application_id |> changes() |> entries()

  @doc """
  Groups changes, each with its transaction, into one entry per transaction, in the
  order they were made.
  """
  @spec entries([Change.t()]) :: [entry()]
  def entries(changes) do
    changes
    |> Enum.sort_by(&{DateTime.to_unix(&1.transaction.inserted_at, :microsecond), &1.id})
    |> with_before()
    |> Enum.chunk_by(fn {change, _before} -> change.transaction_id end)
    |> Enum.map(&entry/1)
  end

  defp changes(application_id) do
    id = to_string(application_id)
    tables = Map.keys(@columns)

    Change
    |> where([c], c.table_prefix == "public")
    |> where(
      [c],
      (c.table_name == "credit_applications" and c.table_pk == ^[id]) or
        (c.table_name in ^tables and fragment("? ->> 'application_id' = ?", c.data, ^id))
    )
    |> preload(transaction: ^put_query_prefix(Transaction, @prefix))
    |> put_query_prefix(@prefix)
    |> Repo.all()
  end

  # Each change paired with the row's data as its previous change left it
  defp with_before(changes) do
    changes
    |> Enum.map_reduce(%{}, fn change, rows ->
      key = {change.table_name, change.table_pk}
      {{change, Map.get(rows, key, %{})}, Map.put(rows, key, change.data)}
    end)
    |> elem(0)
  end

  defp entry([{%{transaction: transaction}, _before} | _rest] = changes) do
    meta = transaction.meta || %{}

    %{
      id: transaction.id,
      at: transaction.inserted_at,
      actor: meta["actor"],
      reason: meta["reason"],
      action: meta["action"],
      country: meta["country"],
      correlation_id: meta["correlation_id"],
      changes: Enum.map(changes, &summary/1)
    }
  end

  defp summary({change, before}) do
    columns = Map.fetch!(@columns, change.table_name)

    %{
      table: change.table_name,
      op: change.op,
      changed: Enum.filter(change.changed || [], &(&1 in columns)),
      data: Map.take(change.data || %{}, columns),
      before: Map.take(before, columns)
    }
  end
end
