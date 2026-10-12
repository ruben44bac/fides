defmodule Fides.Platform.AuditedTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Fides.Platform.Audited.Info

  defp statements(resource) do
    Map.new(AshPostgres.DataLayer.Info.custom_statements(resource), &{&1.name, &1})
  end

  # Resources defined while the test runs. Ash derives an Inspect implementation for
  # each one, and the warning about protocols already being consolidated is discarded.
  defp define(fun), do: capture_io(:stderr, fun)

  test "an audited table gets the Carbonite trigger keyed by its primary key" do
    %{carbonite_capture: capture} = statements(Fides.Countries.Country)

    assert capture.code?
    assert capture.up =~ ~s|Carbonite.Migrations.create_trigger("countries")|
    assert capture.up =~ ~s|:primary_key_columns, ["code"]|
    assert capture.down == ~s|Carbonite.Migrations.drop_trigger("countries")|
  end

  test "per-country tables keep country_code immutable, and filtered columns reach Carbonite" do
    define(fn ->
      defmodule Elixir.Fides.Countries.PerCountryProbe do
        use Fides.Platform.Resource, domain: Fides.Countries.TestDomain

        postgres do
          table "per_country_probes"
          repo Fides.Platform.Repo
        end

        audit do
          immutable [:label]
          filtered [:secret]
        end

        multitenancy do
          strategy :attribute
          attribute :country_code
        end

        attributes do
          uuid_v7_primary_key :id
          attribute :country_code, :string, allow_nil?: false
          attribute :label, :string
          attribute :secret, :string
        end

        classification do
          attribute :id, :pseudonymous
          attribute :country_code, :public
          attribute :label, :public
          attribute :secret, :internal
        end
      end
    end)

    probe = Fides.Countries.PerCountryProbe
    %{carbonite_capture: capture, immutable_columns: trigger} = statements(probe)

    refute capture.up =~ "primary_key_columns"
    assert capture.up =~ ~s|:filtered_columns, ["secret"]|

    assert Info.immutable_columns(probe) == [:country_code, :label]
    assert trigger.up =~ "fides_forbid_column_change('country_code', 'label')"
    assert trigger.down =~ "DROP TRIGGER per_country_probes_immutable_columns"
  end

  test "a table can opt out of capture" do
    define(fn ->
      defmodule Elixir.Fides.Countries.UncapturedProbe do
        use Fides.Platform.Resource, domain: Fides.Countries.TestDomain

        postgres do
          table "uncaptured_probes"
          repo Fides.Platform.Repo
        end

        audit do
          capture? false
        end

        attributes do
          uuid_v7_primary_key :id
        end

        classification do
          attribute :id, :pseudonymous
        end
      end
    end)

    assert statements(Fides.Countries.UncapturedProbe) == %{}
  end

  test "resources outside Postgres get no triggers" do
    assert AshPostgres.DataLayer.Info.custom_statements(Fides.Countries.SensitiveProbe) == []
  end

  test "audit options must name existing attributes" do
    assert_raise Spark.Error.DslError,
                 ~r/audit options name unknown attributes: \[:ghost\]/,
                 fn ->
                   defmodule Elixir.Fides.Countries.UnknownAuditProbe do
                     use Fides.Platform.Resource, domain: Fides.Countries.TestDomain

                     postgres do
                       table "unknown_audit_probes"
                       repo Fides.Platform.Repo
                     end

                     audit do
                       immutable [:ghost]
                     end

                     attributes do
                       uuid_v7_primary_key :id
                     end

                     classification do
                       attribute :id, :pseudonymous
                     end
                   end
                 end
  end

  test "the platform extension installs Carbonite and the immutability function" do
    install = Fides.Platform.PostgresExtension.install(0)
    assert install =~ "Carbonite.Migrations.up(1..12)"
    assert install =~ "CREATE FUNCTION fides_forbid_column_change()"

    uninstall = Fides.Platform.PostgresExtension.uninstall(1)
    assert uninstall =~ "DROP FUNCTION IF EXISTS fides_forbid_column_change()"
    assert uninstall =~ "Carbonite.Migrations.down(12..1//-1)"
  end
end
