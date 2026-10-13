defmodule Fides.Risk.PolicyVersionsTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false

  alias Fides.AgentFlow
  alias Fides.Factory
  alias Fides.Origination
  alias Fides.Platform.SystemActor
  alias Fides.Risk

  @system SystemActor.new(:orchestrator)

  setup do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    first = Factory.policy_in_force("ES", admin)
    AgentFlow.provider_answers("ES")

    %{admin: admin, first: first, analyst: Factory.scoped_staff("ES", :analyst, admin)}
  end

  test "names a country's thresholds, the common ones first" do
    assert Risk.param_names("ES") ==
             {:ok,
              [
                :history_window_days,
                :income_tolerance_percent,
                :countersign_above_minor,
                :review_above_amount_minor
              ]}

    assert {:ok, [:history_window_days, :income_tolerance_percent | own]} = Risk.param_names("BR")
    assert own == [:approve_min_score, :review_min_score]
    assert Risk.param_names("XX") == {:error, :unsupported_country}
  end

  test "lists the versions newest first, each with what it decided", ctx do
    # One application decided under v1, in review above 20 000 EUR
    application =
      Factory.insert(fn ->
        Origination.submit_application!(
          Factory.submission(amount_minor: 2_500_000, monthly_income_minor: 250_000),
          tenant: "ES",
          actor: ctx.analyst
        )
      end)

    application = AgentFlow.decided(application)
    assert %{state: :in_review} = application

    # A second version reviews only above 30 000 EUR; the system reevaluates under it
    {:ok, params} = Risk.default_params("ES")
    proposer = Factory.scoped_staff("ES", :risk_manager, ctx.admin)
    approver = Factory.scoped_staff("ES", :risk_manager, ctx.admin)

    second =
      Factory.insert(fn ->
        %{params | review_above_amount_minor: 3_000_000}
        |> Risk.propose_policy!(tenant: "ES", actor: proposer)
        |> Risk.publish_policy!(tenant: "ES", actor: approver)
      end)

    reevaluating =
      Factory.insert(fn ->
        Origination.reevaluate_application!(
          application,
          "the policy changed",
          application.lock_version,
          tenant: "ES",
          actor: @system
        )
      end)

    :ok = AgentFlow.agent(reevaluating, "risk")

    assert {:ok, [newest, oldest]} = Risk.policy_versions("ES", ctx.analyst)
    assert %{version: 2, status: :published, decisions_count: 1, reevaluations_count: 1} = newest
    assert %{version: 1, status: :retired, decisions_count: 1, reevaluations_count: 0} = oldest
    assert newest.id == second.id and oldest.id == ctx.first.id

    # Out of the actor's countries there is nothing to read
    assert {:ok, []} = Risk.policy_versions("ES", Factory.scoped_staff("MX", :analyst, ctx.admin))
  end
end
