defmodule Fides.Orchestration.AgentJobTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false
  use Oban.Testing, repo: Fides.Platform.Repo

  import ExUnit.CaptureLog

  alias Fides.Factory
  alias Fides.Orchestration
  alias Fides.Orchestration.AgentJob
  alias Fides.Orchestration.Agents.Intake
  alias Fides.Orchestration.Assignment
  alias Fides.Orchestration.CaseFact
  alias Fides.Orchestration.Orchestrator
  alias Fides.Origination
  alias Fides.Platform.AgentActor
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

  # An application that has just entered validation
  defp validating(submission, country, analyst) do
    Factory.insert(fn ->
      submission
      |> Origination.submit_application!(tenant: country, actor: analyst)
      |> Origination.transition_application!(:validating, 1, tenant: country, actor: @system)
    end)
  end

  defp spanish(ctx), do: validating(Factory.submission(), "ES", ctx.analyst)

  defp run_intake(application) do
    perform_job(AgentJob, %{
      agent: "intake",
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

  defp facts(application),
    do: Orchestration.list_case_facts!(tenant: application.country_code, actor: @system)

  defp runs(application),
    do: Orchestration.list_agent_runs!(tenant: application.country_code, actor: @system)

  defp run_info, do: %{job_id: 1, attempt: 1, started: System.monotonic_time(:millisecond)}

  test "Intake checks the holder, and the orchestrator moves on with what it found", ctx do
    application = spanish(ctx)

    assert :ok = run_intake(application)
    assert %{state: :awaiting_bank_data, lock_version: 3} = current(application)

    assert Map.new(facts(application), &{&1.name, &1.value}) == %{
             "document" => %{"valid" => true},
             "adulthood" => %{"adult" => nil, "verified_at" => nil}
           }

    for fact <- facts(application) do
      assert %{agent: :intake, tool: "identity.validate_document", lock_version: 2} = fact
      assert fact.hash == CaseFact.hash(fact.name, fact.value)
    end

    assert [run] = runs(application)

    assert %{
             agent: :intake,
             agent_version: 1,
             attempt: 1,
             lock_version: 2,
             outcome: :advance,
             proposed_state: :awaiting_bank_data
           } = run

    assert run.input_hash == application |> Assignment.new() |> Assignment.hash()
  end

  test "in Mexico, Intake finds the holder an adult, as the CURP proves", ctx do
    application = validating(Factory.mexican_submission(), "MX", ctx.mexican)

    assert :ok = run_intake(application)

    assert [%{"adult" => true, "verified_at" => verified_at}] =
             for(%{name: "adulthood", value: value} <- facts(application), do: value)

    assert {:ok, _at, 0} = DateTime.from_iso8601(verified_at)
  end

  test "a job runs on the version the step saw: once the application moves, a retry does nothing",
       ctx do
    application = spanish(ctx)

    assert :ok = run_intake(application)
    assert {:cancel, :superseded} = run_intake(application)

    assert [%{outcome: :advance}] = runs(application)
    assert length(facts(application)) == 2
  end

  test "two confirmations of the same version make one move, and the second is dropped", ctx do
    application = spanish(ctx)
    proposal = Intake.run(Assignment.new(application))

    results =
      [
        Task.async(fn -> Orchestrator.confirm(application, Intake, proposal, run_info()) end),
        Task.async(fn -> Orchestrator.confirm(application, Intake, proposal, run_info()) end)
      ]
      |> Task.await_many()

    assert results == [:ok, :ok]
    assert current(application).lock_version == application.lock_version + 1

    assert application |> runs() |> Enum.map(& &1.outcome) |> Enum.sort() == [
             :advance,
             :superseded
           ]

    assert length(facts(application)) == 2
  end

  test "retries and escalations are recorded, and the application stays where it is", ctx do
    application = spanish(ctx)

    assert {:error, "the provider timed out"} =
             Orchestrator.confirm(
               application,
               Intake,
               {:retry, "the provider timed out"},
               run_info()
             )

    capture_log(fn ->
      assert :ok =
               Orchestrator.confirm(
                 application,
                 Intake,
                 {:escalate, "unreadable holder"},
                 run_info()
               )
    end)

    assert current(application).state == :validating

    assert application |> runs() |> Enum.map(&{&1.outcome, &1.reason}) |> Enum.sort() == [
             escalate: "unreadable holder",
             retry: "the provider timed out"
           ]
  end

  test "each agent has its own identity: Intake reads the holder, but never moves an application",
       ctx do
    application = spanish(ctx)

    assert {:ok, _found} =
             Fides.Identity.check_holder("ES", application.person_id, AgentActor.new(:intake))

    assert {:error, %Ash.Error.Forbidden{}} =
             Origination.transition_application(
               application,
               :awaiting_bank_data,
               application.lock_version,
               tenant: "ES",
               actor: AgentActor.new(:intake)
             )
  end
end
