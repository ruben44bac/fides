defmodule FidesWeb.ApplicationLiveTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use FidesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fides.AgentFlow
  alias Fides.Factory
  alias Fides.Origination

  setup %{conn: conn} do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    Factory.policy_in_force("ES", admin)
    AgentFlow.provider_answers("ES")

    {analyst, secret} = Factory.staff_user()
    Factory.scope(analyst, "ES", :analyst, admin)
    analyst = Fides.Accounts.load_actor(analyst)

    {mexican, mexican_secret} = Factory.staff_user()
    Factory.scope(mexican, "MX", :analyst, admin)

    %{
      conn: staff_session(conn, analyst, secret),
      mexican_conn: staff_session(conn, Fides.Accounts.load_actor(mexican), mexican_secret),
      analyst: analyst
    }
  end

  defp submit(overrides, ctx) do
    Factory.insert(fn ->
      Origination.submit_application!(Factory.submission(overrides),
        tenant: "ES",
        actor: ctx.analyst
      )
    end)
  end

  defp path(application), do: ~p"/backoffice/applications/#{application.id}"

  test "shows the terms, the bank data, the decision, the agents' work and the story", ctx do
    # Above 20 000 EUR, Spain's rule sends the application to review
    application =
      %{amount_minor: 2_500_000, monthly_income_minor: 250_000}
      |> submit(ctx)
      |> AgentFlow.decided()

    {:ok, view, html} = live(ctx.conn, path(application))

    assert has_element?(view, "#application-state", "in review")
    assert has_element?(view, "#terms", "EUR 25,000.00")
    assert has_element?(view, "#revision-1", "current")

    # The profile as the provider reported it, with the account masked
    assert has_element?(view, "#bank-data", "720")
    assert has_element?(view, "#bank-data", "1332")
    refute html =~ "ES91 2100"
    assert has_element?(view, "#exchanges", "ok")

    {:ok, [decision]} = Fides.Risk.decisions("ES", application.id, ctx.analyst)
    assert has_element?(view, "#decision-#{decision.id}", "review")
    assert has_element?(view, "#decision-#{decision.id}", "amount above review threshold")
    assert has_element?(view, "#decision-#{decision.id}", "policy v1")
    refute has_element?(view, "#decision-#{decision.id} tr[data-changed]")

    assert has_element?(view, "#case-facts", "bank_profile")
    assert has_element?(view, "#agent-runs", "risk")
    assert has_element?(view, "#agent-runs", "intake")

    # The evidence of the agents' work: each move, each fact, the decision
    assert has_element?(view, "#timeline", "awaiting bank data → evaluating")
    assert has_element?(view, "#timeline", "evaluating → in review")
    assert has_element?(view, "#timeline", "Fact bank_profile, by banking")
    assert has_element?(view, "#timeline", "Decision: review (amount above review threshold)")

    # Nothing personal anywhere on the screen
    refute html =~ "Ana"
    refute html =~ "@example.com"
  end

  test "marks the rules that changed between a decision and the one it replaces", ctx do
    application =
      %{amount_minor: 2_500_000, monthly_income_minor: 250_000}
      |> submit(ctx)
      |> AgentFlow.decided()

    # A policy that reviews only above 30 000 EUR changes the country's rule's mind
    {:ok, params} = Fides.Risk.default_params("ES")
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    proposer = Factory.scoped_staff("ES", :risk_manager, admin)
    approver = Factory.scoped_staff("ES", :risk_manager, admin)

    Factory.insert(fn ->
      %{params | review_above_amount_minor: 3_000_000}
      |> Fides.Risk.propose_policy!(tenant: "ES", actor: proposer)
      |> Fides.Risk.publish_policy!(tenant: "ES", actor: approver)
    end)

    reevaluating =
      Factory.insert(fn ->
        Origination.reevaluate_application!(
          application,
          "the policy changed",
          application.lock_version,
          tenant: "ES",
          actor: Fides.Platform.SystemActor.new(:orchestrator)
        )
      end)

    :ok = AgentFlow.agent(reevaluating, "risk")

    {:ok, view, _html} = live(ctx.conn, path(application))
    {:ok, [second, first]} = Fides.Risk.decisions("ES", application.id, ctx.analyst)

    assert has_element?(view, "#application-state", "approved")
    assert has_element?(view, "#decision-#{second.id}", "reevaluation")

    assert has_element?(
             view,
             "#decision-#{second.id} tr[data-changed]",
             "amount review threshold"
           )

    assert has_element?(view, "#decision-#{second.id}", "policy v2")
    refute has_element?(view, "#decision-#{first.id} tr[data-changed]")
  end

  test "a fresh application says what is still to come", ctx do
    application = submit(%{}, ctx)
    {:ok, view, _html} = live(ctx.conn, path(application))

    assert has_element?(view, "#application-state", "submitted")
    assert has_element?(view, "#bank-data", "No bank data yet")
    assert has_element?(view, "#decisions", "No decision yet")
    assert has_element?(view, "#agents", "No agent has run yet")
    refute has_element?(view, "#exchanges")
  end

  test "follows the application as it moves", ctx do
    application = submit(%{}, ctx)
    {:ok, view, _html} = live(ctx.conn, path(application))
    assert has_element?(view, "#application-state", "submitted")

    moved = AgentFlow.start(application)

    Fides.Platform.ChangeListener.broadcast(
      Jason.encode!(%{
        id: application.id,
        country_code: "ES",
        state: "validating",
        lock_version: moved.lock_version
      }),
      Fides.PubSub
    )

    assert has_element?(view, "#application-state", "validating")

    # Another application's change does not disturb this one
    other = submit(%{}, ctx)

    Fides.Platform.ChangeListener.broadcast(
      Jason.encode!(%{id: other.id, country_code: "ES", state: "cancelled", lock_version: 2}),
      Fides.PubSub
    )

    assert has_element?(view, "#application-state", "validating")
  end

  test "an application outside the actor's countries, or unknown, sends back to the inbox",
       ctx do
    application = submit(%{}, ctx)

    assert {:error, {:live_redirect, %{to: "/backoffice", flash: flash}}} =
             live(ctx.mexican_conn, path(application))

    assert flash["error"] =~ "outside your countries"

    assert {:error, {:live_redirect, %{to: "/backoffice"}}} =
             live(ctx.conn, ~p"/backoffice/applications/#{Ash.UUIDv7.generate()}")

    assert {:error, {:live_redirect, %{to: "/backoffice"}}} =
             live(ctx.conn, ~p"/backoffice/applications/not-an-id")
  end

  test "opens from the inbox", ctx do
    application = submit(%{}, ctx)
    {:ok, view, _html} = live(ctx.conn, ~p"/backoffice")

    view |> element("#application-#{application.id} a") |> render_click()
    assert_redirect(view, path(application))
  end
end
