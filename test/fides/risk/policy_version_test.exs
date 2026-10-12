defmodule Fides.Risk.PolicyVersionTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false

  alias Fides.Factory
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor
  alias Fides.Risk

  setup do
    Factory.countries()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    {auditor, _secret} = Factory.staff_user(global_role: :auditor)

    actors = %{
      admin: admin,
      auditor: auditor,
      system: SystemActor.new(:orchestrator),
      proposer: Factory.scoped_staff("MX", :risk_manager, admin),
      approver: Factory.scoped_staff("MX", :risk_manager, admin),
      analyst: Factory.scoped_staff("MX", :analyst, admin),
      foreign: Factory.scoped_staff("CO", :risk_manager, admin)
    }

    AuditContext.put(actor: "staff_user:" <> actors.proposer.id, reason: "policy change")
    {:ok, params} = Risk.default_params("MX")

    Map.put(actors, :params, params)
  end

  defp propose(ctx, params \\ nil),
    do: Risk.propose_policy(params || ctx.params, tenant: "MX", actor: ctx.proposer)

  defp publish(version, actor), do: Risk.publish_policy(version, tenant: "MX", actor: actor)

  # Runs SQL in a savepoint, so a refused statement leaves the test's transaction usable
  defp raw(sql, params) do
    Factory.insert(fn -> Repo.transaction(fn -> Repo.query!(sql, params) end) end)
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  describe "proposing" do
    test "a risk manager proposes thresholds as a draft, numbered after the last version", ctx do
      assert {:ok, first} = propose(ctx)
      assert %{version: 1, status: :draft, approved_by: nil} = first
      assert first.proposed_by == ctx.proposer.id

      assert {:ok, %{version: 2}} = propose(ctx, %{ctx.params | min_income_percent_of_amount: 25})
    end

    test "thresholds the country's policy does not accept create nothing", ctx do
      assert {:error, error} = propose(ctx, Map.put(ctx.params, :score, 1))
      assert Exception.message(error) =~ "unknown thresholds: score"
      assert Risk.list_policy_versions!(tenant: "MX", actor: ctx.admin) == []
    end
  end

  describe "putting a version in force" do
    test "takes a risk manager other than the proposer", ctx do
      {:ok, draft} = propose(ctx)

      assert {:error, error} = publish(draft, ctx.proposer)
      assert Exception.message(error) =~ "someone other than who proposed the version"

      assert {:ok, published} = publish(draft, ctx.approver)
      assert %{status: :published, effective_from: %DateTime{}} = published
      assert published.approved_by == ctx.approver.id
      assert Risk.policy_in_force!(tenant: "MX", actor: ctx.analyst).id == draft.id
    end

    test "retires the version it replaces", ctx do
      {:ok, first} = propose(ctx)
      {:ok, _first} = publish(first, ctx.approver)
      {:ok, second} = propose(ctx, %{ctx.params | min_income_percent_of_amount: 25})
      {:ok, _second} = publish(second, ctx.approver)

      statuses =
        "MX"
        |> then(&Risk.list_policy_versions!(tenant: &1, actor: ctx.admin))
        |> Map.new(&{&1.version, &1.status})

      assert statuses == %{1 => :retired, 2 => :published}
      assert Risk.policy_in_force!(tenant: "MX", actor: ctx.admin).version == 2
    end

    test "happens once", ctx do
      {:ok, draft} = propose(ctx)
      {:ok, _published} = publish(draft, ctx.approver)

      assert {:error, %Ash.Error.Invalid{}} = publish(draft, ctx.approver)
    end
  end

  describe "who may" do
    test "only risk managers of the country propose or publish", ctx do
      {:ok, draft} = propose(ctx)

      for actor <- [ctx.system, ctx.admin, ctx.auditor, ctx.analyst, ctx.foreign] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Risk.propose_policy(ctx.params, tenant: "MX", actor: actor)

        assert {:error, %Ash.Error.Forbidden{}} = publish(draft, actor)
      end
    end

    test "the system, staff of the country, admins and auditors read versions, and nobody without a country",
         ctx do
      {:ok, _draft} = propose(ctx)

      for actor <- [ctx.system, ctx.analyst, ctx.admin, ctx.auditor] do
        assert [_draft] = Risk.list_policy_versions!(tenant: "MX", actor: actor)
      end

      assert Risk.list_policy_versions!(tenant: "MX", actor: ctx.foreign) == []
      assert {:error, %Ash.Error.Invalid{}} = Risk.list_policy_versions(actor: ctx.admin)
    end
  end

  describe "the database" do
    test "refuses a version approved by its proposer or in force without an approver", ctx do
      {:ok, draft} = propose(ctx)

      assert_raise Postgrex.Error, ~r/policy_versions_two_people/, fn ->
        raw(
          "UPDATE policy_versions SET status = 'published', approved_by = proposed_by WHERE id = $1",
          [dump(draft.id)]
        )
      end

      assert_raise Postgrex.Error, ~r/policy_versions_approved_when_in_force/, fn ->
        raw("UPDATE policy_versions SET status = 'published' WHERE id = $1", [dump(draft.id)])
      end
    end

    test "keeps a version's number and thresholds, and one version in force per country", ctx do
      {:ok, first} = propose(ctx)
      {:ok, _first} = publish(first, ctx.approver)
      {:ok, second} = propose(ctx)

      assert_raise Postgrex.Error, ~r/policy_versions_params_immutable/, fn ->
        raw("UPDATE policy_versions SET params = '{}' WHERE id = $1", [dump(second.id)])
      end

      assert_raise Postgrex.Error, ~r/policy_versions_in_force_index/, fn ->
        raw(
          "UPDATE policy_versions SET status = 'published', approved_by = $2 WHERE id = $1",
          [dump(second.id), dump(ctx.approver.id)]
        )
      end
    end
  end
end
