defmodule Fides.Platform.Audited.Persisters.AddAuditTriggers do
  @moduledoc false
  # Adds the audit triggers as AshPostgres custom statements, so `mix ash.codegen`
  # writes them into the same migration as the table. Runs as a persister, after
  # every transformer, when all attributes are known.

  use Spark.Dsl.Transformer

  alias Fides.Platform.Audited.Info
  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl) do
    if AshPostgres.DataLayer in Transformer.get_persisted(dsl, :extensions, []) do
      add_triggers(dsl)
    else
      {:ok, dsl}
    end
  end

  defp add_triggers(dsl) do
    attributes = dsl |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)
    country_code = if :country_code in attributes, do: [:country_code], else: []
    immutable = Enum.uniq(country_code ++ Info.audit_immutable!(dsl))
    filtered = Info.audit_filtered!(dsl)

    case (immutable ++ filtered) -- attributes do
      [] ->
        table = AshPostgres.DataLayer.Info.table(dsl)

        dsl =
          dsl
          |> maybe_add(Info.audit_capture?(dsl), fn -> capture_statement(dsl, table, filtered) end)
          |> maybe_add(immutable != [], fn -> immutable_statement(table, immutable) end)
          |> maybe_add(Info.audit_append_only?(dsl), fn -> append_only_statement(table) end)
          |> Transformer.persist(:fides_immutable_columns, immutable)

        {:ok, dsl}

      unknown ->
        {:error,
         Spark.Error.DslError.exception(
           module: Transformer.get_persisted(dsl, :module),
           path: [:audit],
           message: "audit options name unknown attributes: #{inspect(unknown)}"
         )}
    end
  end

  defp maybe_add(dsl, false, _statement), do: dsl

  defp maybe_add(dsl, true, statement) do
    Transformer.add_entity(dsl, [:postgres, :custom_statements], statement.())
  end

  defp capture_statement(dsl, table, filtered) do
    primary_key = dsl |> Ash.Resource.Info.primary_key() |> Enum.map(&to_string/1)

    up =
      [
        "Carbonite.Migrations.create_trigger(#{inspect(table)})",
        primary_key != ["id"] &&
          "Carbonite.Migrations.put_trigger_config(#{inspect(table)}, :primary_key_columns, #{inspect(primary_key)})",
        filtered != [] &&
          "Carbonite.Migrations.put_trigger_config(#{inspect(table)}, :filtered_columns, #{inspect(Enum.map(filtered, &to_string/1))})"
      ]
      |> Enum.filter(& &1)
      |> Enum.join("\n")

    %AshPostgres.Statement{
      name: :carbonite_capture,
      up: up,
      down: "Carbonite.Migrations.drop_trigger(#{inspect(table)})",
      code?: true,
      global?: false,
      after_tables: []
    }
  end

  defp append_only_statement(table) do
    %AshPostgres.Statement{
      name: :append_only,
      up: """
      CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION fides_forbid_change()
      """,
      down: "DROP TRIGGER #{table}_append_only ON #{table}",
      code?: false,
      global?: false,
      after_tables: []
    }
  end

  defp immutable_statement(table, columns) do
    arguments = Enum.map_join(columns, ", ", &"'#{&1}'")

    %AshPostgres.Statement{
      name: :immutable_columns,
      up: """
      CREATE TRIGGER #{table}_immutable_columns BEFORE UPDATE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION fides_forbid_column_change(#{arguments})
      """,
      down: "DROP TRIGGER #{table}_immutable_columns ON #{table}",
      code?: false,
      global?: false,
      after_tables: []
    }
  end
end
