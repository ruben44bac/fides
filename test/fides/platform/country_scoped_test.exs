defmodule Fides.Platform.CountryScopedTest do
  use ExUnit.Case, async: true

  defp statements(resource) do
    Map.new(AshPostgres.DataLayer.Info.custom_statements(resource), &{&1.name, &1})
  end

  test "per-country tables reject unknown countries and expose (country_code, id)" do
    %{country_foreign_key: foreign_key, country_id_unique: unique} =
      statements(Fides.Identity.Person)

    assert foreign_key.up =~ "FOREIGN KEY (country_code) REFERENCES countries (code)"
    assert foreign_key.after_tables == ["countries"]
    assert unique.up =~ "ON people (country_code, id)"
  end

  test "a table keyed by more than id gets no (country_code, id) index" do
    statements = statements(Fides.Identity.DocumentType)

    assert Map.has_key?(statements, :country_foreign_key)
    refute Map.has_key?(statements, :country_id_unique)
  end

  test "resources without a country are left alone" do
    refute Map.has_key?(statements(Fides.Countries.Country), :country_foreign_key)
  end

  test "a per-country resource must use the country as its tenant" do
    assert_raise Spark.Error.DslError, ~r/use country_code as their tenant/, fn ->
      defmodule Elixir.Fides.Countries.UntenantedProbe do
        use Fides.Platform.Resource,
          domain: Fides.Countries.TestDomain,
          data_layer: Ash.DataLayer.Ets

        attributes do
          uuid_v7_primary_key :id
          attribute :country_code, :string, allow_nil?: false
        end

        classification do
          attribute :id, :pseudonymous
          attribute :country_code, :public
        end
      end
    end
  end
end
