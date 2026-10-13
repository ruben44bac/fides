defmodule Fides.Orchestration.BankingAgentTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false
  use Oban.Testing, repo: Fides.Platform.Repo

  alias Fides.Factory
  alias Fides.Orchestration
  alias Fides.Orchestration.AgentJob
  alias Fides.Orchestration.Agents.Banking
  alias Fides.Orchestration.Assignment
  alias Fides.Orchestration.DelayedMove
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

  # An application that has just entered the wait for bank data
  defp awaiting(submission, country, analyst) do
    Factory.insert(fn ->
      submission
      |> Origination.submit_application!(tenant: country, actor: analyst)
      |> Origination.transition_application!(:validating, 1, tenant: country, actor: @system)
      |> Origination.transition_application!(:awaiting_bank_data, 2,
        tenant: country,
        actor: @system
      )
    end)
  end

  defp spanish(ctx), do: awaiting(Factory.submission(), "ES", ctx.analyst)
  defp mexican(ctx), do: awaiting(Factory.mexican_submission(), "MX", ctx.mexican)

  defp answer(body, status \\ 200) do
    Req.Test.stub(Fides.Banking.Client, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  defp run_banking(application, opts \\ []) do
    perform_job(
      AgentJob,
      %{
        agent: "banking",
        application_id: application.id,
        country_code: application.country_code,
        lock_version: application.lock_version
      },
      opts
    )
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

  defp facts(application) do
    application.country_code
    |> then(&Orchestration.list_case_facts!(tenant: &1, actor: @system))
    |> Map.new(&{&1.name, &1.value})
  end

  defp runs(application),
    do: Orchestration.list_agent_runs!(tenant: application.country_code, actor: @system)

  test "on entering the wait for bank data, Banking runs in the queue of the country's provider",
       ctx do
    application = spanish(ctx)
    assert :ok = step(application)

    assert [%{queue: "banking_es", args: %{"agent" => "banking"}}] =
             all_enqueued(worker: AgentJob)

    assert Banking.queue(Assignment.new(mexican(ctx))) == :banking_mx
  end

  test "with a provider that answers at once, it keeps the profile and the evaluation follows",
       ctx do
    application = spanish(ctx)
    answer(File.read!("test/fixtures/banking/es.json"))

    assert :ok = run_banking(application)
    assert %{state: :evaluating, lock_version: 4} = current(application)

    [profile] = Fides.Banking.list_bank_profiles!(tenant: "ES", actor: @system)
    assert profile.application_id == application.id

    assert %{"bank_profile" => %{"id" => id, "origin" => "live"}} = facts(application)
    assert id == profile.id

    assert [%{agent: :banking, outcome: :advance, proposed_state: :evaluating}] =
             runs(application)
  end

  test "in Mexico, the provider accepts the request and the application waits for its webhook",
       ctx do
    application = mexican(ctx)
    answer(~s({"request_id":"any","status":"accepted"}), 202)

    assert :ok = run_banking(application)
    assert %{state: :awaiting_bank_callback} = waiting = current(application)

    request_id = Banking.request_id(Assignment.new(application))
    assert %{"bank_request" => %{"request_id" => ^request_id}} = facts(application)
    assert {:ok, %{status: :pending}} = Fides.Banking.pending_exchange("MX", request_id, @system)

    # The step then gives the provider until the timeout
    assert :ok = step(waiting)

    assert [%{args: %{"to" => "provider_error", "lock_version" => 4}}] =
             all_enqueued(worker: DelayedMove)
  end

  test "a provider that fails is retried, and when the retries run out the application is in provider_error",
       ctx do
    application = spanish(ctx)
    answer("", 500)

    assert {:error, "the provider answered 500"} = run_banking(application)
    assert current(application).state == :awaiting_bank_data
    assert [%{outcome: :retry, reason: "the provider answered 500"}] = runs(application)

    assert :ok = run_banking(application, attempt: 5, max_attempts: 5)
    assert %{state: :provider_error} = failed = current(application)
    assert %{"provider_error" => %{"reason" => "the provider answered 500"}} = facts(application)

    # From there, a retry back to the bank data is scheduled
    assert :ok = step(failed)
    assert [%{args: %{"to" => "awaiting_bank_data"}} = job] = all_enqueued(worker: DelayedMove)

    assert :ok = perform_job(DelayedMove, job.args)
    assert current(application).state == :awaiting_bank_data
  end

  test "a scheduled move only happens if the application is still where it was", ctx do
    application = spanish(ctx)

    Factory.insert(fn ->
      Origination.transition_application!(application, :provider_error, 3,
        tenant: "ES",
        actor: @system
      )
    end)

    assert {:cancel, :superseded} =
             perform_job(DelayedMove, %{
               application_id: application.id,
               country_code: "ES",
               lock_version: 3,
               to: "evaluating"
             })

    assert current(application).state == :provider_error
  end
end
