defmodule Fides.Countries.SeedsTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false

  alias Fides.Countries.Seeds

  @tag spec: "CTRY-01"
  test "creates the six countries with their currency and data region, and is idempotent" do
    Seeds.run()
    first = snapshot()

    assert first == %{
             "BR" => {"BRL", :latam},
             "CO" => {"COP", :latam},
             "ES" => {"EUR", :eu},
             "IT" => {"EUR", :eu},
             "MX" => {"MXN", :latam},
             "PT" => {"EUR", :eu}
           }

    Seeds.run()
    assert snapshot() == first
  end

  @tag spec: "CTRY-05"
  test "seeding writes with the system actor and its reason" do
    Seeds.run()

    meta = current_carbonite_transaction().meta
    assert meta["actor"] == "system:seeds"
    assert meta["reason"] == "seed reference data"
  end

  @tag spec: "CTRY-05"
  test "writing a country without an audit context fails" do
    [es | _] = Seeds.countries()

    assert {:error, error} =
             Fides.Countries.seed_country(es, actor: Fides.Platform.SystemActor.new(:test))

    assert Exception.message(error) =~ "without prior INSERT into carbonite_default.transactions"
  end

  test "a country is fetched by its code" do
    Fides.Factory.countries()

    assert %{currency: "MXN", data_region: :latam} = Fides.Countries.get_country!("MX")
    assert {:error, %Ash.Error.Invalid{}} = Fides.Countries.get_country("ZZ")
  end

  test "only a system actor can seed" do
    [es | _] = Seeds.countries()
    Fides.Platform.AuditContext.put(actor: "system:test", reason: "policy check")

    assert {:error, %Ash.Error.Forbidden{} = error} = Fides.Countries.seed_country(es, actor: nil)
    assert Exception.message(error) =~ "actor is a system process"
  end

  test "a country code cannot change once created" do
    Fides.Factory.countries()
    Fides.Platform.AuditContext.put(actor: "system:test", reason: "try to rename")

    error =
      assert_raise Postgrex.Error, fn ->
        Fides.Platform.Repo.query!("UPDATE countries SET code = 'XX' WHERE code = 'ES'")
      end

    assert error.postgres.code == :check_violation
    assert error.postgres.constraint == "countries_code_immutable"
  end

  defp snapshot do
    Map.new(Fides.Countries.list_countries!(), &{&1.code, {&1.currency, &1.data_region}})
  end
end
