defmodule FidesWeb.ApplicationAnswerLiveTest do
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
    policy = Factory.policy_in_force("ES", admin)

    {analyst, secret} = Factory.staff_user()
    Factory.scope(analyst, "ES", :analyst, admin)
    analyst = Fides.Accounts.load_actor(analyst)

    {manager, manager_secret} = Factory.staff_user()
    Factory.scope(manager, "ES", :risk_manager, admin)

    %{
      conn: staff_session(conn, analyst, secret),
      manager_conn: staff_session(conn, Fides.Accounts.load_actor(manager), manager_secret),
      admin: admin,
      analyst: analyst,
      policy: policy
    }
  end

  # An application the analyst asked information about, after the system took it to review
  defp waiting(ctx) do
    Factory.insert(fn ->
      application =
        Enum.reduce(
          [:validating, :awaiting_bank_data, :evaluating],
          Origination.submit_application!(Factory.submission(), tenant: "ES", actor: ctx.analyst),
          fn to, application ->
            Origination.transition_application!(application, to, application.lock_version,
              tenant: "ES",
              actor: @system
            )
          end
        )

      application =
        Origination.transition_application!(
          application,
          :in_review,
          application.lock_version,
          %{policy_version_id: ctx.policy.id},
          tenant: "ES",
          actor: @system
        )

      Origination.transition_application!(
        application,
        :info_requested,
        application.lock_version,
        %{reason: "the payslips are missing"},
        tenant: "ES",
        actor: ctx.analyst
      )
    end)
  end

  defp path(application), do: ~p"/backoffice/applications/#{application.id}"

  test "an analyst answers with the corrected terms, which become the next revision", ctx do
    application = waiting(ctx)
    {:ok, view, _html} = live(ctx.conn, path(application))
    assert has_element?(view, "#application-state", "info requested")

    view |> element("#answer") |> render_click()

    view
    |> form("#answer-form", answer: %{amount: "12000", monthly_income: "3000,50"})
    |> render_submit()

    assert has_element?(view, "#application-state", "validating")
    assert has_element?(view, "#revision-2", "current")
    assert has_element?(view, "#revision-1")
    assert render(view) =~ "Answered: revision 2 is now current."
    refute has_element?(view, "#answer-form")

    assert %{revision: 2, amount_minor: 1_200_000, monthly_income_minor: 300_050} =
             Fides.AgentFlow.current(application)
  end

  test "wrong terms stay next to their fields, and nothing moves", ctx do
    application = waiting(ctx)
    {:ok, view, _html} = live(ctx.conn, path(application))

    view |> element("#answer") |> render_click()

    view
    |> form("#answer-form", answer: %{amount: "0", monthly_income: "abc"})
    |> render_submit()

    assert has_element?(view, "#answer_amount-field", "must be more than zero")
    assert has_element?(view, "#answer_monthly_income-field", "must be an amount")
    assert has_element?(view, "#application-state", "info requested")
    assert %{revision: 1} = Fides.AgentFlow.current(application)
  end

  test "an answer on a version that changed does not happen, and says what the application is now",
       ctx do
    application = waiting(ctx)
    {:ok, view, _html} = live(ctx.conn, path(application))

    view |> element("#answer") |> render_click()
    view |> form("#answer-form", answer: %{amount: "12000"}) |> render_change()

    # Meanwhile a colleague cancels the application
    colleague = Factory.scoped_staff("ES", :analyst, ctx.admin)

    Factory.insert(fn ->
      Origination.transition_application!(
        application,
        :cancelled,
        application.lock_version,
        %{reason: "the holder withdrew"},
        tenant: "ES",
        actor: colleague
      )
    end)

    view
    |> form("#answer-form", answer: %{amount: "12000", monthly_income: "3000"})
    |> render_submit()

    assert has_element?(view, "#answer-conflict", "did not happen")
    assert has_element?(view, "#answer-form input[value='12000']")
    assert %{state: :cancelled, revision: 1} = Fides.AgentFlow.current(application)

    view |> element("#answer-conflict-reload") |> render_click()
    assert has_element?(view, "#application-state", "cancelled")
    assert has_element?(view, "#answer-gone", "no longer waiting for information")
    refute has_element?(view, "#answer-form")
  end

  test "only an analyst answers, and only while the application waits", ctx do
    application = waiting(ctx)

    {:ok, view, _html} = live(ctx.manager_conn, path(application))
    refute has_element?(view, "#answer")

    reviewing =
      Factory.insert(fn ->
        Origination.submit_application!(Factory.submission(), tenant: "ES", actor: ctx.analyst)
      end)

    {:ok, view, _html} = live(ctx.conn, path(reviewing))
    refute has_element?(view, "#answer")
  end
end
