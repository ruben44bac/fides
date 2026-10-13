defmodule Fides.Risk.DecisionRecordTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false

  alias Fides.Factory
  alias Fides.Origination
  alias Fides.Platform.AgentActor
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor
  alias Fides.Risk

  @system SystemActor.new(:test)
  @risk AgentActor.new(:risk)

  setup do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    analyst = Factory.scoped_staff("ES", :analyst, admin)
    policy = Factory.policy_in_force("ES", admin)

    application =
      Factory.insert(fn ->
        Origination.submit_application!(Factory.submission(), tenant: "ES", actor: analyst)
      end)

    {:ok, revision} = Origination.revision("ES", application.id, application.revision, @system)
    [provider] = Fides.Banking.list_bank_providers!(tenant: "ES", actor: @system)

    profile =
      Factory.insert(fn ->
        exchange =
          Fides.Banking.record_provider_exchange!(
            %{
              provider_id: provider.id,
              application_id: application.id,
              request_id: "req-1",
              request_hash: :crypto.hash(:sha256, "request"),
              status: :ok,
              latency_ms: 10,
              attempt: 1
            },
            tenant: "ES",
            actor: @system
          )

        Fides.Banking.record_bank_profile!(
          %{
            provider_id: provider.id,
            application_id: application.id,
            exchange_id: exchange.id,
            observed_income_minor: 300_000,
            total_debt_minor: 0,
            income_months: 6,
            score: 700,
            account_masked: "****1234",
            payload_hash: :crypto.hash(:sha256, "answer")
          },
          tenant: "ES",
          actor: @system
        )
      end)

    AuditContext.put(actor: "agent:risk", reason: "decide")

    %{
      policy: policy,
      evaluation: %{
        country: "ES",
        application_id: application.id,
        revision_id: revision.id,
        bank_profile_id: profile.id,
        inputs: %{
          amount_minor: 1_000_000,
          declared_income_minor: 300_000,
          observed_income_minor: 300_000,
          total_debt_minor: 0,
          score: 700,
          income_months: 6,
          document_valid?: true,
          adult?: nil,
          previous_rejection_on: nil,
          evaluated_on: ~D[2026-10-12]
        }
      }
    }
  end

  test "decides with the version in force and keeps a record the engine reproduces", ctx do
    assert {:ok, decision} = Risk.decide(ctx.evaluation, actor: @risk)

    assert %{outcome: :approve, cause: :evaluation, replaces_id: nil} = decision
    assert decision.policy_version_id == ctx.policy.id

    {:ok, params} = Risk.cast_params("ES", ctx.policy.params)
    inputs = struct!(Fides.Risk.Engine.Inputs, Map.put(ctx.evaluation.inputs, :country, "ES"))
    {:ok, result} = Risk.evaluate(inputs, params)

    assert decision.hash == result.hash
    assert decision.inputs_hash == result.inputs_hash

    assert {:ok, %{id: id}} =
             Risk.latest_decision(ctx.evaluation.application_id, tenant: "ES", actor: @system)

    assert id == decision.id
  end

  test "a later decision replaces the previous one", ctx do
    {:ok, first} = Risk.decide(ctx.evaluation, actor: @risk)

    {:ok, second} =
      Risk.decide(put_in(ctx.evaluation, [:inputs, :amount_minor], 3_000_000), actor: @risk)

    assert %{cause: :reevaluation, replaces_id: replaces, outcome: :review} = second
    assert replaces == first.id

    assert {:ok, %{id: id}} =
             Risk.latest_decision(ctx.evaluation.application_id, tenant: "ES", actor: @system)

    assert id == second.id
  end

  test "without a version in force there is no decision", ctx do
    assert {:error, :no_policy} = Risk.decide(%{ctx.evaluation | country: "PT"}, actor: @risk)
  end

  test "the database refuses to change or delete a decision", ctx do
    {:ok, decision} = Risk.decide(ctx.evaluation, actor: @risk)
    {:ok, id} = Ecto.UUID.dump(decision.id)

    for sql <- [
          "UPDATE decision_records SET outcome = 'reject' WHERE id = $1",
          "DELETE FROM decision_records WHERE id = $1"
        ] do
      assert_raise Postgrex.Error, ~r/decision_records_append_only/, fn ->
        Factory.insert(fn -> Repo.transaction(fn -> Repo.query!(sql, [id]) end) end)
      end
    end
  end
end
