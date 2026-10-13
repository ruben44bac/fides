defmodule FidesWeb.ConsoleLiveTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use FidesWeb.ConnCase, async: false
  use Oban.Testing, repo: Fides.Platform.Repo

  import Phoenix.LiveViewTest

  alias Fides.AgentFlow
  alias Fides.Factory
  alias Fides.Notifications
  alias Fides.Origination
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @system SystemActor.new(:orchestrator)
  @secret "a receiver secret long enough"

  setup %{conn: conn} do
    Factory.reference_data()
    {admin, admin_secret} = Factory.staff_user(global_role: :admin)
    {auditor, auditor_secret} = Factory.staff_user(global_role: :auditor)
    Factory.policy_in_force("ES", admin)

    {analyst, secret} = Factory.staff_user()
    Factory.scope(analyst, "ES", :analyst, admin)
    analyst = Fides.Accounts.load_actor(analyst)

    %{
      conn: staff_session(conn, analyst, secret),
      admin_conn: staff_session(conn, admin, admin_secret),
      auditor_conn: staff_session(conn, auditor, auditor_secret),
      admin: admin,
      analyst: analyst
    }
  end

  defp submit(ctx) do
    Factory.insert(fn ->
      Origination.submit_application!(Factory.submission(), tenant: "ES", actor: ctx.analyst)
    end)
  end

  # A delivery the notifier gave up on, for a receiver the admin registered
  defp failed_delivery(application, ctx) do
    endpoint =
      AuditContext.run(
        [actor: "staff_user:" <> ctx.admin.id, reason: "register a receiver"],
        fn ->
          Notifications.register_endpoint!(
            %{
              name: "Core banking",
              url: "http://receiver.test/core",
              secret: @secret,
              events: [:approved]
            },
            actor: ctx.admin
          )
        end
      )

    Factory.insert(fn ->
      delivery =
        Notifications.announce_delivery!(
          %{
            endpoint_id: endpoint.id,
            event_id: "evt_" <> application.id,
            event_type: :approved,
            application_id: application.id,
            payload: %{"event_id" => "evt_" <> application.id},
            payload_hash: :crypto.hash(:sha256, "payload")
          },
          tenant: "ES",
          actor: @system
        )

      Notifications.record_delivery_attempt!(delivery, :failed, 503, tenant: "ES", actor: @system)
    end)
  end

  test "shows how deep each queue is", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/backoffice/console")
    assert has_element?(view, "#queue-orchestration")
    assert has_element?(view, "#queue-banking_mx")

    # A submission enqueues the orchestrator's next step
    submit(ctx)
    view |> element("#refresh") |> render_click()
    assert has_element?(view, "#queue-orchestration td:nth-child(2)", "1")
  end

  test "shows how each provider has been answering, and the applications waiting on one",
       ctx do
    AgentFlow.provider_answers("ES")
    served = ctx |> submit() |> AgentFlow.start()
    :ok = AgentFlow.agent(served, "intake")
    :ok = AgentFlow.agent(AgentFlow.current(served), "banking")

    stuck =
      Factory.insert(fn ->
        Enum.reduce([:validating, :awaiting_bank_data, :provider_error], submit(ctx), fn to,
                                                                                         app ->
          Origination.transition_application!(app, to, app.lock_version,
            tenant: "ES",
            actor: @system
          )
        end)
      end)

    {:ok, view, _html} = live(ctx.conn, ~p"/backoffice/console")
    assert has_element?(view, "#provider-ES", "healthy")
    assert has_element?(view, "#provider-ES", "1 calls in 24 h, 0 failed")
    assert has_element?(view, "#stuck-#{stuck.id}", "EUR 10,000.00")
    assert has_element?(view, "#stuck-#{stuck.id} a[href='/backoffice/applications/#{stuck.id}']")

    # The provider fails the next call
    Req.Test.stub(Fides.Banking.Client, &Plug.Conn.send_resp(&1, 503, ""))
    failing = ctx |> submit() |> AgentFlow.start()
    :ok = AgentFlow.agent(failing, "intake")
    AgentFlow.agent(AgentFlow.current(failing), "banking")

    view |> element("#refresh") |> render_click()
    assert has_element?(view, "#provider-ES", "failing")
    assert has_element?(view, "#provider-ES", "2 calls in 24 h, 1 failed")
    assert has_element?(view, "#provider-ES", "answered 503")
  end

  test "lists the deliveries that failed, and sends one again on request", ctx do
    application = submit(ctx)
    delivery = failed_delivery(application, ctx)

    {:ok, view, _html} = live(ctx.conn, ~p"/backoffice/console")
    assert has_element?(view, "#delivery-#{delivery.id}", "approved")
    assert has_element?(view, "#delivery-#{delivery.id}", "503")
    # An analyst sees the receiver by id; the admin, by name
    assert has_element?(view, "#delivery-#{delivery.id}", "receiver")
    refute has_element?(view, "#delivery-#{delivery.id}", "Core banking")

    view |> element("#resend-#{delivery.id}") |> render_click()
    assert render(view) =~ "goes out again"
    assert has_element?(view, "#failed-none")

    assert %{state: :pending} =
             Notifications.get_delivery!(delivery.id, tenant: "ES", actor: @system)

    assert_enqueued(
      worker: Notifications.Deliver,
      args: %{country_code: "ES", delivery_id: delivery.id}
    )

    {:ok, admin, _html} = live(ctx.admin_conn, ~p"/backoffice/console")
    assert has_element?(admin, "#failed-none")
  end

  test "an admin names receivers and resends; an auditor only looks", ctx do
    application = submit(ctx)
    delivery = failed_delivery(application, ctx)

    {:ok, admin, _html} = live(ctx.admin_conn, ~p"/backoffice/console")
    assert has_element?(admin, "#delivery-#{delivery.id}", "Core banking")
    assert has_element?(admin, "#resend-#{delivery.id}")

    {:ok, auditor, _html} = live(ctx.auditor_conn, ~p"/backoffice/console")
    assert has_element?(auditor, "#delivery-#{delivery.id}", "Core banking")
    refute has_element?(auditor, "#resend-#{delivery.id}")
    assert has_element?(auditor, "#queue-risk")
  end
end
