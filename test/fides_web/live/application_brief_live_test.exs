defmodule FidesWeb.ApplicationBriefLiveTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use FidesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fides.AgentFlow
  alias Fides.Factory
  alias Fides.Origination
  alias Fides.Platform.AgentActor

  setup %{conn: conn} do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    Factory.policy_in_force("ES", admin)
    AgentFlow.provider_answers("ES")

    {analyst, secret} = Factory.staff_user()
    Factory.scope(analyst, "ES", :analyst, admin)
    analyst = Fides.Accounts.load_actor(analyst)

    application =
      Factory.insert(fn ->
        Origination.submit_application!(
          Factory.submission(amount_minor: 2_500_000, monthly_income_minor: 250_000),
          tenant: "ES",
          actor: analyst
        )
      end)

    %{conn: staff_session(conn, analyst, secret), reviewed: AgentFlow.decided(application)}
  end

  test "shows the brief once a model wrote it", ctx do
    path = ~p"/backoffice/applications/#{ctx.reviewed.id}"

    {:ok, view, _html} = live(ctx.conn, path)
    refute has_element?(view, "#case-brief")

    {:ok, _run} = Fides.AI.brief(ctx.reviewed, AgentActor.new(:ai))

    {:ok, view, _html} = live(ctx.conn, path)
    assert has_element?(view, "#case-brief", "simulated model")
    assert has_element?(view, "#brief-summary", "EUR 25,000.00")
    assert has_element?(view, "#brief-summary", "sent it to review")
    assert has_element?(view, "#brief-signals", "amount review threshold")
    assert has_element?(view, "#case-brief", "guardrails passed")
  end
end
