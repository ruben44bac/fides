defmodule Fides.Orchestration.RiskAgentTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false
  use Oban.Testing, repo: Fides.Platform.Repo

  import ExUnit.CaptureLog

  alias Fides.Factory
  alias Fides.Orchestration
  alias Fides.Orchestration.AgentJob
  alias Fides.Origination
  alias Fides.Platform.SystemActor
  alias Fides.Risk

  @system SystemActor.new(:orchestrator)

  setup do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    answer(File.read!("test/fixtures/banking/es.json"))

    %{admin: admin, analyst: Factory.scoped_staff("ES", :analyst, admin)}
  end

  defp answer(body) do
    Req.Test.stub(Fides.Banking.Client, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp agent(application, name) do
    perform_job(AgentJob, %{
      agent: name,
      application_id: application.id,
      country_code: "ES",
      lock_version: application.lock_version
    })
  end

  defp current(application),
    do: Origination.get_application!(application.id, tenant: "ES", authorize?: false)

  # An application the way the orchestrator brings it to the evaluation: validated by
  # Intake, with its bank profile from Banking
  defp evaluating(ctx, overrides) do
    application =
      Factory.insert(fn ->
        Factory.submission(overrides)
        |> Origination.submit_application!(tenant: "ES", actor: ctx.analyst)
        |> Origination.transition_application!(:validating, 1, tenant: "ES", actor: @system)
      end)

    :ok = agent(application, "intake")
    :ok = application |> current() |> agent("banking")
    current(application)
  end

  # The holder's income is 2 500 EUR as the bank sees it
  defp good_terms, do: %{amount_minor: 1_000_000, monthly_income_minor: 250_000}

  defp decisions, do: Risk.list_decisions!(tenant: "ES", actor: @system)

  defp facts(application) do
    {:ok, facts} = Orchestration.case_facts("ES", application.id, @system)
    facts
  end

  test "approves an application the policy approves, and keeps the decision", ctx do
    policy = Factory.policy_in_force("ES", ctx.admin)
    application = evaluating(ctx, good_terms())

    assert :ok = agent(application, "risk")
    assert %{state: :approved, policy_version_id: policy_id} = current(application)
    assert policy_id == policy.id

    assert [decision] = decisions()
    {:ok, revision} = Origination.revision("ES", application.id, application.revision, @system)
    [profile] = Fides.Banking.list_bank_profiles!(tenant: "ES", actor: @system)

    assert %{
             outcome: :approve,
             reason_codes: [],
             cause: :evaluation,
             replaces_id: nil,
             application_id: application_id,
             revision_id: revision_id,
             bank_profile_id: profile_id,
             policy_version_id: policy_version_id
           } = decision

    assert {application_id, revision_id, profile_id, policy_version_id} ==
             {application.id, revision.id, profile.id, policy.id}

    assert %{
             "amount_minor" => 1_000_000,
             "declared_income_minor" => 250_000,
             "observed_income_minor" => 250_000,
             "score" => 720,
             "document_valid?" => true,
             "adult?" => nil,
             "previous_rejection_on" => nil
           } = decision.inputs

    assert Enum.map(decision.rule_results, & &1["rule"]) == [
             "eligibility",
             "history",
             "income_consistency",
             "amount_review_threshold"
           ]

    assert byte_size(decision.hash) == 32
    assert decision.engine_sha == Fides.Platform.Build.code_sha()

    assert %{"decision" => %{"outcome" => "approve", "id" => id}} = facts(application)
    assert id == decision.id
  end

  test "sends to review what the country's rule or the common rules send there", ctx do
    Factory.policy_in_force("ES", ctx.admin)

    # Above 20 000 EUR, Spain reviews
    large = evaluating(ctx, %{amount_minor: 2_500_000, monthly_income_minor: 250_000})
    assert :ok = agent(large, "risk")
    assert %{state: :in_review} = current(large)

    # The bank sees far less income than declared
    mismatch = evaluating(ctx, %{amount_minor: 1_000_000, monthly_income_minor: 400_000})
    assert :ok = agent(mismatch, "risk")
    assert %{state: :in_review} = current(mismatch)

    assert decisions() |> Enum.map(&{&1.outcome, &1.reason_codes}) |> Enum.sort() == [
             {:review, [:amount_above_review_threshold]},
             {:review, [:income_mismatch]}
           ]
  end

  test "rejects when Intake found the document invalid", ctx do
    Factory.policy_in_force("ES", ctx.admin)
    application = evaluating(ctx, good_terms())

    Factory.insert(fn ->
      Orchestration.record_case_fact!(
        %{
          application_id: application.id,
          name: "document",
          value: %{valid: false},
          agent: :intake,
          tool: "identity.validate_document",
          lock_version: application.lock_version
        },
        tenant: "ES",
        actor: @system
      )
    end)

    assert :ok = agent(application, "risk")
    assert %{state: :rejected} = current(application)
    assert [%{outcome: :reject, reason_codes: [:invalid_document]}] = decisions()
  end

  test "a holder rejected within the window goes to review when they apply again", ctx do
    Factory.policy_in_force("ES", ctx.admin)
    holder = Factory.holder()
    first = evaluating(ctx, Map.put(good_terms(), :holder, holder))

    Factory.insert(fn ->
      Orchestration.record_case_fact!(
        %{
          application_id: first.id,
          name: "document",
          value: %{valid: false},
          agent: :intake,
          tool: "identity.validate_document",
          lock_version: first.lock_version
        },
        tenant: "ES",
        actor: @system
      )
    end)

    :ok = agent(first, "risk")
    assert current(first).state == :rejected

    # Intake finds the document fine this time, and the terms are good: the history decides
    retry = evaluating(ctx, Map.put(good_terms(), :holder, holder))
    assert :ok = agent(retry, "risk")
    assert %{state: :in_review} = current(retry)

    assert %{reason_codes: [:recent_rejection], inputs: %{"previous_rejection_on" => on}} =
             decisions() |> Enum.find(&(&1.application_id == retry.id))

    assert on == Date.to_iso8601(Date.utc_today())
  end

  test "escalates without a policy version in force, or without a bank profile", ctx do
    without_policy = evaluating(ctx, good_terms())

    capture_log(fn -> assert :ok = agent(without_policy, "risk") end)
    assert current(without_policy).state == :evaluating

    Factory.policy_in_force("ES", ctx.admin)

    without_profile =
      Factory.insert(fn ->
        Factory.submission(good_terms())
        |> Origination.submit_application!(tenant: "ES", actor: ctx.analyst)
        |> Origination.transition_application!(:validating, 1, tenant: "ES", actor: @system)
        |> Origination.transition_application!(:awaiting_bank_data, 2,
          tenant: "ES",
          actor: @system
        )
        |> Origination.transition_application!(:evaluating, 3, tenant: "ES", actor: @system)
      end)

    capture_log(fn -> assert :ok = agent(without_profile, "risk") end)
    assert current(without_profile).state == :evaluating

    reasons =
      Orchestration.list_agent_runs!(tenant: "ES", actor: @system)
      |> Enum.filter(&(&1.agent == :risk))
      |> Enum.map(&{&1.outcome, &1.reason})
      |> Enum.sort()

    assert reasons == [
             {:escalate, "no policy version is in force in ES"},
             {:escalate, "the application has no bank profile"}
           ]

    assert decisions() == []
  end

  test "the Risk agent sees no personal data", _ctx do
    for resource <- [
          Fides.Orchestration.CaseFact,
          Fides.Banking.BankProfile,
          Fides.Risk.DecisionRecord
        ] do
      classes = Fides.Platform.Classification.Info.classes(resource)
      refute :pii in Map.values(classes), inspect(resource)
    end

    assignment = Fides.Orchestration.Assignment.__struct__() |> Map.keys()
    refute Enum.any?(assignment, &(&1 in [:name, :document, :email]))
  end
end
