defmodule Fides.Orchestration.StepTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false
  use Oban.Testing, repo: Fides.Platform.Repo

  alias Fides.Factory
  alias Fides.Orchestration.AgentJob
  alias Fides.Orchestration.Step
  alias Fides.Origination
  alias Fides.Platform.SystemActor

  @system SystemActor.new(:orchestrator)

  setup do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)

    %{
      analyst: Factory.scoped_staff("ES", :analyst, admin),
      mexican: Factory.scoped_staff("MX", :analyst, admin)
    }
  end

  defp submit(submission, country, analyst) do
    Factory.insert(fn ->
      Origination.submit_application!(submission, tenant: country, actor: analyst)
    end)
  end

  defp move!(application, to) do
    Factory.insert(fn ->
      Origination.transition_application!(application, to, application.lock_version,
        tenant: application.country_code,
        actor: @system
      )
    end)
  end

  defp step(application) do
    perform_job(Step, %{
      application_id: application.id,
      country_code: application.country_code,
      lock_version: application.lock_version
    })
  end

  defp current(application) do
    Origination.get_application!(application.id,
      tenant: application.country_code,
      authorize?: false
    )
  end

  test "on entering submitted, the orchestrator moves the application to validating", ctx do
    application = submit(Factory.submission(), "ES", ctx.analyst)

    assert :ok = step(application)
    assert %{state: :validating, lock_version: 2} = current(application)

    assert %{"actor" => "system:orchestrator", "reason" => "entering validating"} =
             current_carbonite_transaction().meta
  end

  test "each country's step runs what its life cycle declares", ctx do
    mexican = submit(Factory.mexican_submission(), "MX", ctx.mexican)

    assert :ok = step(mexican)
    assert %{state: :validating} = current(mexican)
  end

  test "a step for a version the application has left does nothing", ctx do
    application = submit(Factory.submission(), "ES", ctx.analyst)
    moved = move!(application, :validating)

    assert {:cancel, :superseded} = step(application)
    assert current(application).lock_version == moved.lock_version
    refute_enqueued worker: AgentJob
  end

  test "on entering validating, Intake runs in its own queue, once per version", ctx do
    application = Factory.submission() |> submit("ES", ctx.analyst) |> move!(:validating)

    assert :ok = step(application)
    assert :ok = step(application)

    assert [job] = all_enqueued(worker: AgentJob)
    assert job.queue == "intake"

    assert %{"agent" => "intake", "application_id" => id, "lock_version" => 2} = job.args
    assert id == application.id
  end

  test "an effect whose agent does not exist yet waits", ctx do
    application =
      Factory.submission()
      |> submit("ES", ctx.analyst)
      |> move!(:validating)
      |> move!(:awaiting_bank_data)
      |> move!(:evaluating)

    assert :ok = step(application)
    refute_enqueued worker: AgentJob
    assert current(application).state == :evaluating
  end
end
