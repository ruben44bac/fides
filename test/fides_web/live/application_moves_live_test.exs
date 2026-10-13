defmodule FidesWeb.ApplicationLiveMovesTest do
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

    {auditor, auditor_secret} = Factory.staff_user(global_role: :auditor)

    %{
      conn: staff_session(conn, analyst, secret),
      manager_conn: staff_session(conn, Fides.Accounts.load_actor(manager), manager_secret),
      auditor_conn: staff_session(conn, auditor, auditor_secret),
      admin: admin,
      analyst: analyst,
      policy: policy
    }
  end

  # An application in review, moved there by the system under the policy in force
  defp in_review(overrides, ctx) do
    Factory.insert(fn ->
      application =
        Enum.reduce(
          [:validating, :awaiting_bank_data, :evaluating],
          Origination.submit_application!(Factory.submission(overrides),
            tenant: "ES",
            actor: ctx.analyst
          ),
          fn to, application ->
            Origination.transition_application!(application, to, application.lock_version,
              tenant: "ES",
              actor: @system
            )
          end
        )

      Origination.transition_application!(
        application,
        :in_review,
        application.lock_version,
        %{policy_version_id: ctx.policy.id},
        tenant: "ES",
        actor: @system
      )
    end)
  end

  defp path(application), do: ~p"/backoffice/applications/#{application.id}"

  defp move(view, to, reason) do
    view |> element("#move-#{to}") |> render_click()
    view |> form("#move-form", move: %{reason: reason}) |> render_submit()
  end

  test "offers exactly the moves the actor may make now", ctx do
    small = in_review(%{amount_minor: 2_500_000}, ctx)
    {:ok, view, _html} = live(ctx.conn, path(small))

    for to <- ~w(approved rejected info_requested cancelled),
        do: assert(has_element?(view, "#move-#{to}"))

    refute has_element?(view, "#move-pending_countersign")
    refute has_element?(view, "#move-validating")
    refute has_element?(view, "#move-form")

    # Above 50 000 EUR an analyst's approval needs a countersignature
    large = in_review(%{amount_minor: 6_000_000}, ctx)
    {:ok, view, _html} = live(ctx.conn, path(large))
    assert has_element?(view, "#move-pending_countersign")
    refute has_element?(view, "#move-approved")

    # In review, a risk manager has nothing to do, and an auditor never does
    {:ok, view, _html} = live(ctx.manager_conn, path(large))
    assert has_element?(view, "#moves", "Nothing for you to do")
    {:ok, view, _html} = live(ctx.auditor_conn, path(large))
    assert has_element?(view, "#moves", "Nothing for you to do")
  end

  test "moves the application with a reason, and shows it as it stands after", ctx do
    application = in_review(%{amount_minor: 2_500_000}, ctx)
    {:ok, view, _html} = live(ctx.conn, path(application))

    move(view, "rejected", "The income does not support the amount.")

    assert has_element?(view, "#application-state", "rejected")
    assert has_element?(view, "#moves", "which is final")
    refute has_element?(view, "#move-form")
    assert render(view) =~ "Moved to rejected."
    assert %{state: :rejected, lock_version: 6} = Fides.AgentFlow.current(application)
  end

  test "without a reason, says so next to the field and changes nothing", ctx do
    application = in_review(%{amount_minor: 2_500_000}, ctx)
    {:ok, view, _html} = live(ctx.conn, path(application))

    move(view, "rejected", "   ")

    assert has_element?(view, "#move-form", "is required from a person")
    assert has_element?(view, "#application-state", "in review")
    assert %{state: :in_review} = Fides.AgentFlow.current(application)
  end

  test "above the threshold an analyst's approval waits for a risk manager's", ctx do
    application = in_review(%{amount_minor: 6_000_000}, ctx)
    {:ok, view, _html} = live(ctx.conn, path(application))

    move(view, "pending_countersign", "The figures hold up.")
    assert has_element?(view, "#application-state", "pending countersign")
    assert has_element?(view, "#move-cancelled")
    refute has_element?(view, "#move-approved")

    {:ok, manager, _html} = live(ctx.manager_conn, path(application))
    assert has_element?(manager, "#move-approved")
    assert has_element?(manager, "#move-in_review")
    refute has_element?(manager, "#move-rejected")

    move(manager, "approved", "Countersigned.")
    assert has_element?(manager, "#application-state", "approved")
    assert has_element?(manager, "#moves", "which is final")
  end

  test "a move on a version that changed does not happen, and the reason written stays",
       ctx do
    application = in_review(%{amount_minor: 2_500_000}, ctx)
    {:ok, view, _html} = live(ctx.conn, path(application))

    view |> element("#move-rejected") |> render_click()
    view |> form("#move-form", move: %{reason: "Fraud suspected."}) |> render_change()

    # Meanwhile a colleague asks the holder for information
    colleague = Factory.scoped_staff("ES", :analyst, ctx.admin)

    Factory.insert(fn ->
      Origination.transition_application!(
        application,
        :info_requested,
        application.lock_version,
        %{reason: "the payslips are missing"},
        tenant: "ES",
        actor: colleague
      )
    end)

    view |> form("#move-form", move: %{reason: "Fraud suspected."}) |> render_submit()

    assert has_element?(view, "#move-conflict", "did not happen")
    assert has_element?(view, "#move-form textarea", "Fraud suspected.")
    assert %{state: :info_requested} = Fides.AgentFlow.current(application)

    # Read again: the application is waiting for information, so a rejection is no
    # longer possible, and the reason is still there to copy or rewrite
    view |> element("#move-conflict-reload") |> render_click()
    assert has_element?(view, "#application-state", "info requested")
    assert has_element?(view, "#move-error", "no longer possible")
    assert has_element?(view, "#move-form textarea", "Fraud suspected.")
    assert has_element?(view, "#move-form button[type=submit][disabled]")
    refute has_element?(view, "#move-conflict")
  end
end
