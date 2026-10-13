defmodule Fides.Orchestration.ReevaluationTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false
  use Oban.Testing, repo: Fides.Platform.Repo

  alias Fides.Factory
  alias Fides.Orchestration.AgentJob
  alias Fides.Orchestration.Reevaluation
  alias Fides.Orchestration.Step
  alias Fides.Origination
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor
  alias Fides.Risk

  @system SystemActor.new(:orchestrator)

  setup do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    analyst = Factory.scoped_staff("ES", :analyst, admin)
    policy = Factory.policy_in_force("ES", admin)

    %{
      admin: admin,
      analyst: analyst,
      policy: policy,
      proposer: Factory.scoped_staff("ES", :risk_manager, admin),
      approver: Factory.scoped_staff("ES", :risk_manager, admin)
    }
  end

  # An application waiting for review, decided under `policy`
  defp in_review(ctx, policy) do
    Factory.insert(fn ->
      Factory.submission(amount_minor: 2_500_000)
      |> Origination.submit_application!(tenant: "ES", actor: ctx.analyst)
      |> Origination.transition_application!(:validating, 1, tenant: "ES", actor: @system)
      |> Origination.transition_application!(:awaiting_bank_data, 2, tenant: "ES", actor: @system)
      |> Origination.transition_application!(:evaluating, 3, tenant: "ES", actor: @system)
      |> Origination.transition_application!(:in_review, 4, %{policy_version_id: policy.id},
        tenant: "ES",
        actor: @system
      )
    end)
  end

  defp publish_next(ctx) do
    {:ok, params} = Risk.default_params("ES")

    AuditContext.run([actor: "staff_user:" <> ctx.proposer.id, reason: "new thresholds"], fn ->
      Risk.propose_policy!(%{params | review_above_amount_minor: 3_000_000},
        tenant: "ES",
        actor: ctx.proposer
      )
      |> Risk.publish_policy!(tenant: "ES", actor: ctx.approver)
    end)
  end

  defp current(application),
    do: Origination.get_application!(application.id, tenant: "ES", authorize?: false)

  test "publishing a policy version sends the applications waiting under an older one back to evaluation",
       ctx do
    waiting = in_review(ctx, ctx.policy)

    submitted =
      Factory.insert(fn ->
        Origination.submit_application!(Factory.submission(), tenant: "ES", actor: ctx.analyst)
      end)

    next = publish_next(ctx)

    # Exactly one job for the new version; the first version's seed enqueued its own
    assert [job] = all_enqueued(worker: Reevaluation, args: %{policy_version_id: next.id})
    assert %{"country_code" => "ES", "policy_version_id" => _id} = job.args

    assert :ok = perform_job(Reevaluation, job.args)

    assert %{state: :evaluating, lock_version: 6} = current(waiting)
    assert current(submitted).state == :submitted

    # Its own step then runs the Risk agent
    assert :ok =
             perform_job(Step, %{application_id: waiting.id, country_code: "ES", lock_version: 6})

    assert [%{queue: "risk", args: %{"agent" => "risk"}}] = all_enqueued(worker: AgentJob)
  end

  test "an application already decided under the new version, or no longer in review, is left alone",
       ctx do
    next = publish_next(ctx)
    under_next = in_review(ctx, next)
    cancelled = in_review(ctx, ctx.policy)

    Factory.insert(fn ->
      Origination.transition_application!(cancelled, :cancelled, 5, %{reason: "withdrew"},
        tenant: "ES",
        actor: ctx.analyst
      )
    end)

    assert :ok = perform_job(Reevaluation, %{country_code: "ES", policy_version_id: next.id})

    assert current(under_next).state == :in_review
    assert current(cancelled).state == :cancelled
  end

  test "running the same reevaluation again changes nothing", ctx do
    waiting = in_review(ctx, ctx.policy)
    next = publish_next(ctx)
    args = %{country_code: "ES", policy_version_id: next.id}

    assert :ok = perform_job(Reevaluation, args)
    assert :ok = perform_job(Reevaluation, args)
    assert %{state: :evaluating, lock_version: 6} = current(waiting)
  end
end
