defmodule Fides.Platform.AuditContextTest do
  use Fides.DataCase, async: true

  alias Fides.Countries.Country
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @mx %{
    code: "MX",
    currency: "MXN",
    default_locale: "es-MX",
    timezone: "America/Mexico_City",
    data_region: :latam
  }

  defp seed(attrs \\ @mx), do: Fides.Countries.seed_country(attrs, actor: SystemActor.new(:test))

  describe "without an audit context" do
    @tag spec: "AUDT-01"
    test "a write to an audited table fails in the database" do
      assert {:error, error} = seed()

      assert Exception.message(error) =~
               "without prior INSERT into carbonite_default.transactions"

      assert Fides.Countries.list_countries!() == []
    end

    @tag spec: "AUDT-08"
    test "only the factory can write, and capture is back on afterwards" do
      Fides.Factory.countries()
      assert length(Fides.Countries.list_countries!()) == 6
      assert current_carbonite_transaction() == nil

      assert {:error, error} = seed(%{@mx | default_locale: "es-419"})

      assert Exception.message(error) =~
               "without prior INSERT into carbonite_default.transactions"
    end
  end

  describe "with an audit context" do
    @tag spec: "AUDT-02"
    test "the transaction records actor, action, reason, country, correlation, trace and code" do
      AuditContext.put(
        actor: "system:test",
        reason: "create Mexico",
        country: "MX",
        traceparent: "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
      )

      assert {:ok, _country} = seed()

      meta = current_carbonite_transaction().meta

      assert meta["actor"] == "system:test"
      assert meta["action"] == "Fides.Countries.Country.seed"
      assert meta["reason"] == "create Mexico"
      assert meta["country"] == "MX"
      assert meta["correlation_id"] == AuditContext.get().correlation_id
      assert meta["traceparent"] == "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
      assert is_binary(meta["code_sha"]) and meta["code_sha"] != ""

      assert {:ok, [change]} = Carbonite.fetch_changes(Fides.Platform.Repo)
      assert change.table_name == "countries"
      assert change.table_pk == ["MX"]
    end

    @tag spec: "AUDT-04"
    test "bulk writes run inside an audited transaction" do
      AuditContext.put(actor: "system:test", reason: "bulk seed")

      result =
        Ash.bulk_create(Fides.Countries.Seeds.countries(), Country, :seed,
          actor: SystemActor.new(:test),
          return_errors?: true
        )

      assert result.status == :success
      assert {:ok, changes} = Carbonite.fetch_changes(Fides.Platform.Repo)
      assert length(changes) == 6
    end

    @tag spec: "AUDT-04"
    test "the repo never runs an action or an atomic update without a transaction" do
      assert Fides.Platform.Repo.prefer_transaction?()
      assert Fides.Platform.Repo.prefer_transaction_for_atomic_updates?()
    end
  end

  describe "the repo" do
    test "targets PostgreSQL 18, with timestamptz columns and the platform extension" do
      assert Fides.Platform.Repo.min_pg_version().major == 18
      assert Fides.Platform.Repo.use_timestamptz?()
      assert Fides.Platform.PostgresExtension in Fides.Platform.Repo.installed_extensions()
    end
  end

  test "a context needs an actor and a reason" do
    assert_raise ArgumentError, ~r/non-empty actor/, fn -> AuditContext.new(reason: "x") end

    assert_raise ArgumentError, ~r/non-empty reason/, fn ->
      AuditContext.new(actor: "system:x")
    end
  end

  describe "meta/2" do
    test "takes the action from the Ash transaction unless the context names one" do
      context = AuditContext.new(actor: "system:test", reason: "check")
      reason = %{type: :create, metadata: %{resource: Country, action: :seed, tenant: "MX"}}

      assert %{"action" => "Fides.Countries.Country.seed", "country" => "MX"} =
               AuditContext.meta(context, reason)

      assert %{"action" => "countries.reseed"} =
               AuditContext.meta(%{context | action: "countries.reseed"}, reason)
    end

    test "accepts keyword metadata and transactions without a resource" do
      context = AuditContext.new(actor: "system:test", reason: "check")

      assert %{"action" => "Fides.Countries.Country.seed"} =
               AuditContext.meta(context, %{metadata: [resource: Country, action: :seed]})

      assert %{"action" => nil, "country" => nil} = AuditContext.meta(context)
    end
  end

  test "factory suppression survives nested contexts and is restored afterwards" do
    AuditContext.suppress(fn ->
      AuditContext.suppress(fn -> :ok end)
      AuditContext.put(actor: "system:test", reason: "inside a factory")
      assert AuditContext.begin_transaction(Fides.Platform.Repo, %{}) == :ok
      assert current_carbonite_transaction() == nil
    end)

    AuditContext.clear()
    assert AuditContext.get() == nil
  end

  test "run/2 restores the previous context" do
    AuditContext.put(actor: "system:outer", reason: "outer")

    AuditContext.run([reason: "inner"], fn ->
      assert %{actor: "system:outer", reason: "inner"} = AuditContext.get()
    end)

    assert %{reason: "outer"} = AuditContext.get()
  end

  @tag spec: "AUDT-05"
  test "no audited table is partitioned" do
    %{rows: rows} =
      Fides.Platform.Repo.query!("""
      SELECT c.relname
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      WHERE t.tgname = 'capture_changes_into_carbonite_default_trigger'
        AND (c.relkind = 'p' OR c.relispartition)
      """)

    assert rows == []
  end
end
