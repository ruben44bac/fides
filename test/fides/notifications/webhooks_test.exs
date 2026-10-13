defmodule Fides.Notifications.WebhooksTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false
  use Oban.Testing, repo: Fides.Platform.Repo

  alias Fides.Factory
  alias Fides.Notifications
  alias Fides.Notifications.Deliver
  alias Fides.Notifications.Event
  alias Fides.Notifications.Signature
  alias Fides.Orchestration.Step
  alias Fides.Origination
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @system SystemActor.new(:orchestrator)
  @secret "a receiver secret of sixteen"

  setup do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    analyst = Factory.scoped_staff("ES", :analyst, admin)

    {everywhere, mexico} =
      AuditContext.run([actor: "staff_user:" <> admin.id, reason: "register receivers"], fn ->
        {Notifications.register_endpoint!(
           %{
             name: "Everywhere",
             url: "http://receiver.test/all",
             secret: @secret,
             events: [:approved, :rejected]
           },
           actor: admin
         ),
         Notifications.register_endpoint!(
           %{
             name: "Mexico only",
             url: "http://receiver.test/mx",
             secret: @secret,
             events: [:approved],
             country_filter: "MX"
           },
           actor: admin
         )}
      end)

    %{admin: admin, analyst: analyst, everywhere: everywhere, mexico: mexico}
  end

  # An application the system approved, with the decision's reason codes among its facts
  defp approved(ctx, holder) do
    Factory.insert(fn ->
      application =
        Factory.submission(holder: holder)
        |> Origination.submit_application!(tenant: "ES", actor: ctx.analyst)
        |> Origination.transition_application!(:validating, 1, tenant: "ES", actor: @system)
        |> Origination.transition_application!(:awaiting_bank_data, 2,
          tenant: "ES",
          actor: @system
        )
        |> Origination.transition_application!(:evaluating, 3, tenant: "ES", actor: @system)

      Fides.Orchestration.record_case_fact!(
        %{
          application_id: application.id,
          name: "decision",
          value: %{outcome: "approve", reason_codes: []},
          agent: :risk,
          tool: "risk.evaluate",
          lock_version: 4
        },
        tenant: "ES",
        actor: @system
      )

      Origination.transition_application!(application, :approved, 4, tenant: "ES", actor: @system)
    end)
  end

  defp step(application) do
    perform_job(Step, %{
      application_id: application.id,
      country_code: application.country_code,
      lock_version: application.lock_version
    })
  end

  defp deliveries, do: Notifications.list_deliveries!(tenant: "ES", actor: @system)

  defp receiver(status) do
    test = self()

    Req.Test.stub(Deliver, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test,
        {:delivered, conn.request_path, Plug.Conn.get_req_header(conn, "x-signature"), body}
      )

      Plug.Conn.send_resp(conn, status, "")
    end)
  end

  test "entering a state announces it to the receivers subscribed to it in the country, once",
       ctx do
    holder = Factory.holder()
    application = approved(ctx, holder)

    assert :ok = step(application)
    assert :ok = step(application)

    assert [delivery] = deliveries()
    assert delivery.endpoint_id == ctx.everywhere.id
    assert %{event_type: :approved, state: :pending, attempts: 0} = delivery
    assert [_job] = all_enqueued(worker: Deliver)

    assert %{
             "type" => "application.approved",
             "state" => "approved",
             "country" => "ES",
             "lock_version" => 5,
             "reason_codes" => [],
             "event_id" => "evt_" <> _
           } = delivery.payload

    assert delivery.payload["application_id"] == application.id

    # Nothing about the holder leaves
    for value <- Map.values(holder), do: refute(Jason.encode!(delivery.payload) =~ value)
  end

  test "a person's move carries no reason codes, a decision carries its own", ctx do
    reviewed =
      Factory.insert(fn ->
        application =
          Factory.submission(amount_minor: 2_500_000)
          |> Origination.submit_application!(tenant: "ES", actor: ctx.analyst)
          |> Origination.transition_application!(:validating, 1, tenant: "ES", actor: @system)
          |> Origination.transition_application!(:awaiting_bank_data, 2,
            tenant: "ES",
            actor: @system
          )
          |> Origination.transition_application!(:evaluating, 3, tenant: "ES", actor: @system)

        Fides.Orchestration.record_case_fact!(
          %{
            application_id: application.id,
            name: "decision",
            value: %{outcome: "review", reason_codes: ["amount_above_review_threshold"]},
            agent: :risk,
            tool: "risk.evaluate",
            lock_version: 4
          },
          tenant: "ES",
          actor: @system
        )

        application
        |> Origination.transition_application!(:in_review, 4, tenant: "ES", actor: @system)
        |> Origination.transition_application!(:rejected, 5, %{reason: "no"},
          tenant: "ES",
          actor: ctx.analyst
        )
      end)

    assert :ok = step(reviewed)
    assert [%{payload: %{"state" => "rejected", "reason_codes" => []}}] = deliveries()
  end

  test "a delivery is signed with the receiver's secret, and marked delivered on a 2xx", ctx do
    application = approved(ctx, Factory.holder())
    :ok = step(application)
    [job] = all_enqueued(worker: Deliver)
    receiver(200)

    assert :ok = perform_job(Deliver, job.args)

    assert_received {:delivered, "/all", [signature], body}
    assert Signature.verify(@secret, signature, body, System.os_time(:second)) == :ok
    assert Jason.decode!(body)["application_id"] == application.id

    assert [%{state: :delivered, attempts: 1, last_status: 200}] = deliveries()
  end

  test "a receiver that fails is tried again, and the delivery fails after the last attempt",
       ctx do
    application = approved(ctx, Factory.holder())
    :ok = step(application)
    [job] = all_enqueued(worker: Deliver)
    receiver(500)

    assert {:error, "the receiver answered 500"} = perform_job(Deliver, job.args)
    assert [%{state: :pending, attempts: 1, last_status: 500}] = deliveries()

    Req.Test.stub(Deliver, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, "the receiver could not be reached: " <> _} =
             perform_job(Deliver, job.args, attempt: 8, max_attempts: 8)

    assert [%{state: :failed, attempts: 2, last_status: nil}] = deliveries()
  end

  test "the same change gives the same event, and a receiver holds it once", ctx do
    application = approved(ctx, Factory.holder())
    id = Event.id(application, :approved)

    assert id == Event.id(application, :approved)
    refute id == Event.id(%{application | lock_version: 9}, :approved)

    :ok = step(application)
    assert :ok = Notifications.announce(application, :approved, [], @system)
    assert [%{event_id: ^id}] = deliveries()
  end

  test "only an admin registers receivers, and only a delivery reads a secret", ctx do
    assert {:error, %Ash.Error.Forbidden{}} =
             Notifications.register_endpoint(
               %{
                 name: "Rogue",
                 url: "http://receiver.test/rogue",
                 secret: @secret,
                 events: [:approved]
               },
               actor: ctx.analyst
             )

    assert {:error, error} = Ash.load(ctx.everywhere, :secret, actor: SystemActor.new(:anyone))
    assert Exception.message(error) =~ "only decrypted to sign a delivery"
  end
end
