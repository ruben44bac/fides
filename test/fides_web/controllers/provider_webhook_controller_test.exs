defmodule FidesWeb.ProviderWebhookControllerTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use FidesWeb.ConnCase, async: false
  use Oban.Testing, repo: Fides.Platform.Repo

  alias Fides.Factory
  alias Fides.Notifications.Signature
  alias Fides.Orchestration.AgentJob
  alias Fides.Orchestration.Agents.Banking
  alias Fides.Orchestration.Assignment
  alias Fides.Orchestration.DelayedMove
  alias Fides.Orchestration.ProviderCallback
  alias Fides.Origination
  alias Fides.Platform.SystemActor

  @system SystemActor.new(:orchestrator)
  @secret "fides test provider webhook secret"

  setup %{conn: conn} do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    analyst = Factory.scoped_staff("MX", :analyst, admin)

    # An application waiting for the provider's webhook, its request accepted
    application =
      Factory.insert(fn ->
        Factory.mexican_submission()
        |> Origination.submit_application!(tenant: "MX", actor: analyst)
        |> Origination.transition_application!(:validating, 1, tenant: "MX", actor: @system)
        |> Origination.transition_application!(:awaiting_bank_data, 2,
          tenant: "MX",
          actor: @system
        )
      end)

    Req.Test.stub(Fides.Banking.Client, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(202, "{}")
    end)

    :ok =
      perform_job(AgentJob, %{
        agent: "banking",
        application_id: application.id,
        country_code: "MX",
        lock_version: application.lock_version
      })

    waiting = Origination.get_application!(application.id, tenant: "MX", authorize?: false)
    assert waiting.state == :awaiting_bank_callback

    %{
      conn: conn,
      application: waiting,
      request_id: Banking.request_id(Assignment.new(application))
    }
  end

  defp event(request_id, event_id \\ "evt_1") do
    "test/fixtures/banking/mx.json"
    |> File.read!()
    |> Jason.decode!()
    |> Map.merge(%{"request_id" => request_id, "event_id" => event_id})
    |> Jason.encode!()
  end

  defp deliver(conn, body, signature \\ nil, country \\ "MX") do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header(
      "x-signature",
      signature || Signature.sign(@secret, body, System.os_time(:second))
    )
    |> post("/webhooks/providers/#{country}", body)
  end

  defp events, do: Fides.Notifications.list_inbound_events!(tenant: "MX", actor: @system)

  defp current(application),
    do: Origination.get_application!(application.id, tenant: "MX", authorize?: false)

  defp apply_deliveries do
    for job <- all_enqueued(worker: ProviderCallback),
        do: :ok = perform_job(ProviderCallback, job.args)
  end

  test "a signed delivery is answered at once, recorded and applied afterwards", ctx do
    response = deliver(ctx.conn, event(ctx.request_id))
    assert json_response(response, 202)

    assert [%{event_id: "evt_1", signature_valid: true, sequence: 3, result: nil}] = events()
    assert current(ctx.application).state == :awaiting_bank_callback

    apply_deliveries()

    assert %{state: :evaluating} = current(ctx.application)
    assert [%{result: :applied, processed_at: %DateTime{}}] = events()

    [profile] = Fides.Banking.list_bank_profiles!(tenant: "MX", actor: @system)

    assert %{
             observed_income_minor: 3_000_050,
             score: 690,
             account_masked: "****7771",
             origin: :live
           } =
             profile

    assert profile.application_id == ctx.application.id

    assert [%{"bank_profile" => %{"id" => id}}] =
             for(
               %{name: "bank_profile", value: value} <-
                 Fides.Orchestration.list_case_facts!(tenant: "MX", actor: @system),
               do: %{"bank_profile" => value}
             )

    assert id == profile.id
  end

  test "a repeated delivery is answered and never applied twice", ctx do
    body = event(ctx.request_id)
    assert json_response(deliver(ctx.conn, body), 202)
    assert json_response(deliver(ctx.conn, body), 202)

    assert [_one] = events()
    assert [_one] = all_enqueued(worker: ProviderCallback)
  end

  test "an invalid signature is refused and recorded, without stopping the genuine event", ctx do
    body = event(ctx.request_id)

    assert json_response(deliver(ctx.conn, body, "t=1,v1=" <> String.duplicate("0", 64)), 401)

    assert json_response(
             deliver(ctx.conn, body, Signature.sign("wrong", body, System.os_time(:second))),
             401
           )

    assert json_response(deliver(ctx.conn, body), 202)

    assert events() |> Enum.map(& &1.signature_valid) |> Enum.sort() == [false, false, true]
    assert [_one] = all_enqueued(worker: ProviderCallback)
  end

  test "a malformed body is recorded as rejected", ctx do
    body =
      ~s({"event_id":"evt_bad","sequence":1,"request_id":"#{ctx.request_id}","perfil":{"score":"alto"}})

    assert json_response(deliver(ctx.conn, body), 400)
    assert [%{event_id: "evt_bad", result: :rejected}] = events()
    refute_enqueued worker: ProviderCallback
  end

  test "a delivery for an application that has moved on, or for no request, changes nothing",
       ctx do
    assert json_response(deliver(ctx.conn, event("req-unknown", "evt_unknown")), 202)

    Factory.insert(fn ->
      Origination.transition_application!(
        ctx.application,
        :cancelled,
        ctx.application.lock_version,
        %{reason: "withdrew"},
        tenant: "MX",
        actor:
          Factory.scoped_staff("MX", :analyst, elem(Factory.staff_user(global_role: :admin), 0))
      )
    end)

    assert json_response(deliver(ctx.conn, event(ctx.request_id, "evt_late")), 202)
    apply_deliveries()

    assert events() |> Enum.map(&{&1.event_id, &1.result}) |> Enum.sort() == [
             {"evt_late", :ignored},
             {"evt_unknown", :ignored}
           ]

    assert Fides.Banking.list_bank_profiles!(tenant: "MX", actor: @system) == []
  end

  test "a country whose provider answers at once has no webhook", ctx do
    assert json_response(deliver(ctx.conn, event(ctx.request_id), nil, "ES"), 404)
    assert json_response(deliver(ctx.conn, event(ctx.request_id), nil, "XX"), 404)
  end

  test "without the webhook, the timeout leaves the application in provider_error", ctx do
    timeout = %{
      application_id: ctx.application.id,
      country_code: "MX",
      lock_version: ctx.application.lock_version,
      to: "provider_error"
    }

    assert :ok = perform_job(DelayedMove, timeout)
    assert current(ctx.application).state == :provider_error
  end
end
