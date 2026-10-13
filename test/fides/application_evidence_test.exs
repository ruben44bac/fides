defmodule Fides.ApplicationEvidenceTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false

  alias Fides.AgentFlow
  alias Fides.Banking
  alias Fides.Factory
  alias Fides.Orchestration
  alias Fides.Origination
  alias Fides.Platform.SystemActor
  alias Fides.Risk

  @system SystemActor.new(:orchestrator)

  setup do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    Factory.policy_in_force("ES", admin)
    AgentFlow.provider_answers("ES")
    analyst = Factory.scoped_staff("ES", :analyst, admin)

    # Above 20 000 EUR, Spain's rule sends the application to review
    application =
      Factory.insert(fn ->
        Origination.submit_application!(
          Factory.submission(amount_minor: 2_500_000, monthly_income_minor: 250_000),
          tenant: "ES",
          actor: analyst
        )
      end)

    %{
      admin: admin,
      analyst: analyst,
      mexican: Factory.scoped_staff("MX", :analyst, admin),
      application: AgentFlow.decided(application)
    }
  end

  # A new version in force, proposed and published by two risk managers
  defp publish(params, ctx) do
    proposer = Factory.scoped_staff("ES", :risk_manager, ctx.admin)
    approver = Factory.scoped_staff("ES", :risk_manager, ctx.admin)

    Factory.insert(fn ->
      params
      |> Risk.propose_policy!(tenant: "ES", actor: proposer)
      |> Risk.publish_policy!(tenant: "ES", actor: approver)
    end)
  end

  test "the revisions from the first, and the moves the actor may make now", ctx do
    assert %{state: :in_review, revision: 1} = ctx.application

    assert {:ok, [revision]} = Origination.revisions("ES", ctx.application.id, ctx.analyst)
    assert %{number: 1, amount_minor: 2_500_000, cause: :submitted} = revision

    # At 25 000 EUR an analyst approves alone, below the countersign threshold
    assert ctx.application |> Origination.available_moves(ctx.analyst) |> Enum.sort() ==
             [:approved, :cancelled, :info_requested, :rejected]

    risk_manager = Factory.scoped_staff("ES", :risk_manager, ctx.admin)
    assert Origination.available_moves(ctx.application, risk_manager) == []
  end

  test "the bank profiles and the calls behind them, newest first", ctx do
    assert {:ok, [profile]} = Banking.profiles("ES", ctx.application.id, ctx.analyst)
    assert %{score: 720, observed_income_minor: 250_000, origin: :live} = profile
    assert String.ends_with?(profile.account_masked, "1332")
    refute profile.account_masked =~ "2100"

    assert {:ok, [exchange]} = Banking.exchanges("ES", ctx.application.id, ctx.analyst)
    assert %{status: :ok, http_status: 200, attempt: 1} = exchange
    assert exchange.id == profile.exchange_id
  end

  test "the decisions, newest first, each with the rules that changed since the one it replaces",
       ctx do
    assert {:ok, [first]} = Risk.decisions("ES", ctx.application.id, ctx.analyst)
    assert %{outcome: :review, reason_codes: [:amount_above_review_threshold]} = first
    assert Risk.changed_rules(first, nil) == []

    # A policy that reviews only above 30 000 EUR changes the country's rule's mind
    {:ok, params} = Risk.default_params("ES")
    publish(%{params | review_above_amount_minor: 3_000_000}, ctx)

    reevaluating =
      Factory.insert(fn ->
        Origination.reevaluate_application!(
          ctx.application,
          "the policy changed",
          ctx.application.lock_version,
          tenant: "ES",
          actor: @system
        )
      end)

    assert :ok = AgentFlow.agent(reevaluating, "risk")
    assert %{state: :approved} = AgentFlow.current(ctx.application)

    assert {:ok, [second, ^first]} = Risk.decisions("ES", ctx.application.id, ctx.analyst)
    assert %{outcome: :approve, cause: :reevaluation, replaces_id: replaces_id} = second
    assert replaces_id == first.id
    assert Risk.changed_rules(second, first) == ["amount_review_threshold"]

    # As the engine gives them, with atoms, the results compare the same
    fresh = %{second | rule_results: Enum.map(second.rule_results, &atoms/1)}
    assert Risk.changed_rules(fresh, first) == ["amount_review_threshold"]
    assert Risk.changed_rules(fresh, second) == []
  end

  test "the facts with who found them, and every run of an agent, newest first", ctx do
    assert {:ok, facts} = Orchestration.case_fact_history("ES", ctx.application.id, ctx.analyst)
    assert %{name: "decision", agent: :risk, tool: "risk.evaluate"} = hd(facts)
    assert Enum.map(facts, & &1.name) |> Enum.sort() |> Enum.dedup() |> length() > 1
    assert "document" in Enum.map(facts, & &1.name)
    assert "bank_profile" in Enum.map(facts, & &1.name)

    assert {:ok, runs} = Orchestration.agent_runs("ES", ctx.application.id, ctx.analyst)

    assert Enum.map(runs, &{&1.agent, &1.outcome, &1.proposed_state}) == [
             {:risk, :advance, :in_review},
             {:banking, :advance, :evaluating},
             {:intake, :advance, :awaiting_bank_data}
           ]
  end

  test "out of the actor's countries, there is nothing to read", ctx do
    reads = [
      &Origination.revisions/3,
      &Banking.profiles/3,
      &Banking.exchanges/3,
      &Risk.decisions/3,
      &Orchestration.case_fact_history/3,
      &Orchestration.agent_runs/3
    ]

    for read <- reads do
      assert {:ok, []} = read.("ES", ctx.application.id, ctx.mexican)
    end
  end

  defp atoms(result) do
    %{
      rule: String.to_atom(result["rule"]),
      outcome: String.to_atom(result["outcome"]),
      reason_codes: Enum.map(result["reason_codes"], &String.to_atom/1)
    }
  end
end
