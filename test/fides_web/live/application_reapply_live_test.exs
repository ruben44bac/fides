defmodule FidesWeb.ApplicationReapplyLiveTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use FidesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fides.Factory
  alias Fides.Origination
  alias Fides.Platform.SystemActor

  @system SystemActor.new(:orchestrator)

  setup %{conn: conn} do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)

    {analyst, secret} = Factory.staff_user()
    Factory.scope(analyst, "ES", :analyst, admin)
    analyst = Fides.Accounts.load_actor(analyst)

    {manager, manager_secret} = Factory.staff_user()
    Factory.scope(manager, "ES", :risk_manager, admin)

    %{
      conn: staff_session(conn, analyst, secret),
      manager_conn: staff_session(conn, Fides.Accounts.load_actor(manager), manager_secret),
      analyst: analyst
    }
  end

  # An application the system decided, as Risk would
  defp decided(outcome, ctx) do
    Factory.insert(fn ->
      Enum.reduce(
        [:validating, :awaiting_bank_data, :evaluating, outcome],
        Origination.submit_application!(Factory.submission(), tenant: "ES", actor: ctx.analyst),
        fn to, application ->
          Origination.transition_application!(application, to, application.lock_version,
            tenant: "ES",
            actor: @system
          )
        end
      )
    end)
  end

  defp path(application), do: ~p"/backoffice/applications/#{application.id}"

  defp applications, do: Origination.list_applications!(tenant: "ES", authorize?: false)

  test "an analyst reapplies for the holder of a rejected application, once", ctx do
    rejected = decided(:rejected, ctx)
    {:ok, view, _html} = live(ctx.conn, path(rejected))
    assert has_element?(view, "#moves", "which is final")

    view |> element("#reapply") |> render_click()

    redirect =
      view
      |> form("#reapply-form",
        reapply: %{amount: "8000", monthly_income: "3000", consent: "true"}
      )
      |> render_submit()

    assert {:error, {:live_redirect, %{to: to}}} = redirect
    assert [retry] = Enum.reject(applications(), &(&1.id == rejected.id))
    assert to == path(retry)

    assert %{
             state: :submitted,
             channel: :form,
             currency: "EUR",
             amount_minor: 800_000,
             monthly_income_minor: 300_000
           } = retry

    assert retry.previous_application_id == rejected.id
    assert retry.person_id == rejected.person_id

    {:ok, _detail, html} = follow_redirect(redirect, ctx.conn)
    assert html =~ "Reapplied"

    # The rejected one now points at its retry, and cannot be retried again
    {:ok, view, _html} = live(ctx.conn, path(rejected))
    assert has_element?(view, "#retried-as", "submitted")
    assert has_element?(view, "#retried-as a[href='#{path(retry)}']")
    refute has_element?(view, "#reapply")
  end

  test "needs the consent and valid terms, and creates nothing without them", ctx do
    cancelled =
      Factory.insert(fn ->
        application =
          Origination.submit_application!(Factory.submission(), tenant: "ES", actor: ctx.analyst)

        Origination.transition_application!(application, :cancelled, 1, %{reason: "withdrew"},
          tenant: "ES",
          actor: ctx.analyst
        )
      end)

    {:ok, view, _html} = live(ctx.conn, path(cancelled))
    view |> element("#reapply") |> render_click()

    view
    |> form("#reapply-form", reapply: %{amount: "8000", monthly_income: "0", consent: "false"})
    |> render_submit()

    assert has_element?(view, "#reapply_monthly_income-field", "must be more than zero")
    assert has_element?(view, "#reapply_consent-field", "must be confirmed")
    assert [_cancelled] = applications()
  end

  test "neither an approved application nor a risk manager reapply", ctx do
    approved = decided(:approved, ctx)
    {:ok, view, _html} = live(ctx.conn, path(approved))
    refute has_element?(view, "#reapply")

    rejected = decided(:rejected, ctx)
    {:ok, view, _html} = live(ctx.manager_conn, path(rejected))
    refute has_element?(view, "#reapply")
  end
end
