defmodule Fides.Orchestration.CapabilityTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false
  use Oban.Testing, repo: Fides.Platform.Repo

  alias Fides.AgentFlow
  alias Fides.AI
  alias Fides.Factory
  alias Fides.Orchestration.Step
  alias Fides.Origination

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

    %{analyst: analyst, reviewed: AgentFlow.decided(application)}
  end

  test "entering review enqueues the brief, and its job writes it as the AI", ctx do
    assert :ok =
             perform_job(Step, %{
               application_id: ctx.reviewed.id,
               country_code: "ES",
               lock_version: ctx.reviewed.lock_version
             })

    assert_enqueued(worker: Fides.AI.CaseBriefJob, args: %{application_id: ctx.reviewed.id})

    assert :ok =
             perform_job(Fides.AI.CaseBriefJob, %{
               application_id: ctx.reviewed.id,
               country_code: "ES",
               lock_version: ctx.reviewed.lock_version
             })

    assert {:ok, %{outcome: :model}} = AI.latest_brief("ES", ctx.reviewed.id, ctx.analyst)
  end

  test "a capability nobody runs waits, without stopping the step", ctx do
    settings = Application.get_env(:fides, Fides.Orchestration, [])
    on_exit(fn -> Application.put_env(:fides, Fides.Orchestration, settings) end)
    Application.put_env(:fides, Fides.Orchestration, Keyword.put(settings, :capabilities, %{}))

    assert :ok =
             perform_job(Step, %{
               application_id: ctx.reviewed.id,
               country_code: "ES",
               lock_version: ctx.reviewed.lock_version
             })

    refute_enqueued(worker: Fides.AI.CaseBriefJob)
  end
end
