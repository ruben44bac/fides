defmodule Fides.Platform.CountryScoped.Persisters.ScopeByCountry do
  @moduledoc false
  # Requires the country as tenant and adds the database constraints as AshPostgres
  # custom statements, so `mix ash.codegen` writes them with the table.

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl) do
    attributes = dsl |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)

    cond do
      :country_code not in attributes -> {:ok, dsl}
      not tenant_is_country?(dsl) -> {:error, tenant_error(dsl)}
      postgres?(dsl) -> {:ok, add_constraints(dsl)}
      true -> {:ok, dsl}
    end
  end

  defp tenant_is_country?(dsl) do
    Ash.Resource.Info.multitenancy_strategy(dsl) == :attribute and
      Ash.Resource.Info.multitenancy_attribute(dsl) == :country_code
  end

  defp tenant_error(dsl) do
    Spark.Error.DslError.exception(
      module: Transformer.get_persisted(dsl, :module),
      path: [:multitenancy],
      message:
        "per-country resources use country_code as their tenant: " <>
          "multitenancy do strategy :attribute; attribute :country_code end"
    )
  end

  defp postgres?(dsl),
    do: AshPostgres.DataLayer in Transformer.get_persisted(dsl, :extensions, [])

  defp add_constraints(dsl) do
    table = AshPostgres.DataLayer.Info.table(dsl)
    foreign_key = "#{table}_country_code_fkey"

    dsl =
      dsl
      |> Transformer.add_entity([:postgres, :custom_statements], %AshPostgres.Statement{
        name: :country_foreign_key,
        up:
          "ALTER TABLE #{table} ADD CONSTRAINT #{foreign_key} " <>
            "FOREIGN KEY (country_code) REFERENCES countries (code)",
        down: "ALTER TABLE #{table} DROP CONSTRAINT #{foreign_key}",
        code?: false,
        global?: false,
        after_tables: ["countries"]
      })
      |> Transformer.set_option(
        [:postgres],
        :foreign_key_names,
        AshPostgres.DataLayer.Info.foreign_key_names(dsl) ++
          [{:country_code, foreign_key, "is not a country Fides operates in"}]
      )

    if Ash.Resource.Info.primary_key(dsl) == [:id] do
      index = "#{table}_country_code_id_index"

      Transformer.add_entity(dsl, [:postgres, :custom_statements], %AshPostgres.Statement{
        name: :country_id_unique,
        up: "CREATE UNIQUE INDEX #{index} ON #{table} (country_code, id)",
        down: "DROP INDEX #{index}",
        code?: false,
        global?: false,
        after_tables: []
      })
    else
      dsl
    end
  end
end
