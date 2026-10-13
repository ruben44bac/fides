defmodule Fides.Identity.PiiAccessTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false

  alias Fides.Factory
  alias Fides.Identity
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @system SystemActor.new(:test)
  @holder %{
    document_type: "DNI",
    document: "12345678Z",
    given_names: "Zoila",
    first_surname: "Quintana",
    second_surname: "Sotomayor",
    email: "zoila.quintana@example.com"
  }

  setup do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    {auditor, _secret} = Factory.staff_user(global_role: :auditor)

    person =
      Factory.insert(fn -> Identity.resolve_person!(@holder, tenant: "ES", actor: @system) end)

    analyst = Factory.scoped_staff("ES", :analyst, admin)
    AuditContext.put(actor: "staff_user:" <> analyst.id, reason: "backoffice")

    %{
      admin: admin,
      auditor: auditor,
      analyst: analyst,
      manager: Factory.scoped_staff("ES", :risk_manager, admin),
      foreign: Factory.scoped_staff("MX", :analyst, admin),
      person: person
    }
  end

  defp accesses, do: Identity.list_pii_accesses!(tenant: "ES", actor: @system)

  # SQL in a savepoint, so a refused statement leaves the test's transaction usable
  defp raw(sql), do: Factory.insert(fn -> Repo.transaction(fn -> Repo.query!(sql) end) end)

  test "reveals a field for a reason, and leaves who, what, of whom, when and why", ctx do
    assert {:ok, %{value: "12345678Z", access: access}} =
             Identity.reveal("ES", ctx.person.id, :document, "the holder called", ctx.analyst)

    assert %{subject_type: :person, field: :document, reason: "the holder called"} = access
    assert %DateTime{} = access.accessed_at
    assert access.subject_id == ctx.person.id
    assert access.accessed_by == ctx.analyst.id

    assert {:ok, %{value: "Zoila Quintana Sotomayor"}} =
             Identity.reveal("ES", ctx.person.id, :name, "identity check", ctx.manager)

    assert {:ok, %{value: "zoila.quintana@example.com"}} =
             Identity.reveal("ES", ctx.person.id, :email, "to call back", ctx.analyst)

    assert accesses() |> Enum.map(& &1.field) |> Enum.sort() == [:document, :email, :name]

    assert {:ok, [newest | _older] = all} =
             Identity.pii_accesses("ES", ctx.person.id, ctx.analyst)

    assert length(all) == 3
    assert newest.field == :email
  end

  test "without a reason, nothing is revealed and nothing is logged", ctx do
    for reason <- [nil, "", "   "] do
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.Required{field: :reason}]}} =
               Identity.reveal("ES", ctx.person.id, :document, reason, ctx.analyst)
    end

    assert accesses() == []
  end

  test "only the staff of the holder's country reveal", ctx do
    for actor <- [ctx.admin, ctx.auditor, ctx.foreign] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Identity.reveal("ES", ctx.person.id, :document, "curious", actor)
    end

    assert accesses() == []

    # Admins and auditors do see who looked
    {:ok, _revealed} = Identity.reveal("ES", ctx.person.id, :document, "a reason", ctx.analyst)
    assert {:ok, [_access]} = Identity.pii_accesses("ES", ctx.person.id, ctx.auditor)
    assert {:ok, []} = Identity.pii_accesses("ES", ctx.person.id, ctx.foreign)
  end

  test "the evidence carries the reason, and the log is never changed or deleted", ctx do
    {:ok, _revealed} =
      Identity.reveal("ES", ctx.person.id, :document, "a reason to remember", ctx.analyst)

    # The first audited write of the test, so its meta is the test's
    assert %{"reason" => "a reason to remember", "actor" => actor} =
             current_carbonite_transaction().meta

    assert actor == "staff_user:" <> ctx.analyst.id

    assert_raise Postgrex.Error, ~r/pii_access_log_append_only/, fn ->
      raw("UPDATE pii_access_log SET reason = 'edited'")
    end

    assert_raise Postgrex.Error, ~r/pii_access_log_append_only/, fn ->
      raw("DELETE FROM pii_access_log")
    end

    assert [%{reason: "a reason to remember"}] = accesses()
  end
end
