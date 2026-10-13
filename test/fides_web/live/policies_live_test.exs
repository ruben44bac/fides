defmodule FidesWeb.PoliciesLiveTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use FidesWeb.ConnCase, async: false
  use Oban.Testing, repo: Fides.Platform.Repo

  import Phoenix.LiveViewTest

  alias Fides.Factory
  alias Fides.Risk

  setup %{conn: conn} do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    {auditor, auditor_secret} = Factory.staff_user(global_role: :auditor)
    first = Factory.policy_in_force("ES", admin)
    Factory.policy_in_force("PT", admin)

    {manager, secret} = Factory.staff_user()
    Factory.scope(manager, "ES", :risk_manager, admin)
    Factory.scope(manager, "PT", :risk_manager, admin)
    manager = Fides.Accounts.load_actor(manager)

    {other, other_secret} = Factory.staff_user()
    Factory.scope(other, "ES", :risk_manager, admin)

    {analyst, analyst_secret} = Factory.staff_user()
    Factory.scope(analyst, "ES", :analyst, admin)

    %{
      conn: staff_session(conn, manager, secret),
      other_conn: staff_session(conn, Fides.Accounts.load_actor(other), other_secret),
      analyst_conn: staff_session(conn, Fides.Accounts.load_actor(analyst), analyst_secret),
      auditor_conn: staff_session(conn, auditor, auditor_secret),
      manager: manager,
      first: first
    }
  end

  defp versions(country), do: Risk.list_policy_versions!(tenant: country, authorize?: false)

  test "shows the version in force with its thresholds, and every version", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/backoffice/policies?country=ES")

    assert has_element?(view, "#in-force", "Version 1")
    assert has_element?(view, "#in-force-review_above_amount_minor", "EUR 20,000.00")
    assert has_element?(view, "#in-force-countersign_above_minor", "EUR 50,000.00")
    assert has_element?(view, "#in-force-income_tolerance_percent", "15 %")
    assert has_element?(view, "#version-#{ctx.first.id}", "published")
    assert has_element?(view, "#version-#{ctx.first.id}", "0 decisions")

    # Portugal has its own thresholds
    view |> element("#country-PT") |> render_click()
    assert_patch(view, ~p"/backoffice/policies?country=PT")
    assert has_element?(view, "#in-force-approve_max_income_multiple", "6 × the income")
    refute has_element?(view, "#in-force-review_above_amount_minor")
  end

  test "a risk manager proposes a version, and another one publishes it", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/backoffice/policies?country=ES")

    # As the proposal is typed, what differs from the version in force is said
    view
    |> form("#propose-form", policy: %{review_above_amount_minor: "30000"})
    |> render_change()

    assert has_element?(view, "#what-changes", "Review above")
    assert has_element?(view, "#what-changes", "EUR 20,000.00")
    assert has_element?(view, "#what-changes", "EUR 30,000.00")

    view
    |> form("#propose-form", policy: %{review_above_amount_minor: "30000"})
    |> render_submit()

    assert render(view) =~ "Version 2 proposed"
    [draft] = Enum.filter(versions("ES"), &(&1.status == :draft))
    assert %{version: 2, params: %{"review_above_amount_minor" => 3_000_000}} = draft

    # The proposer cannot publish it, and sees the thresholds that change
    assert has_element?(view, "#version-#{draft.id}", "draft")
    assert has_element?(view, "#own-draft-#{draft.id}")
    refute has_element?(view, "#publish-#{draft.id}")
    view |> element("#toggle-#{draft.id}") |> render_click()
    assert has_element?(view, "#thresholds-#{draft.id} tr[data-changed]", "EUR 30,000.00")
    assert has_element?(view, "#thresholds-#{draft.id} tr[data-changed]", "EUR 20,000.00")

    # Another risk manager of the country publishes it, which retires v1 and sends the
    # applications waiting under it back to evaluation
    {:ok, other, _html} = live(ctx.other_conn, ~p"/backoffice/policies?country=ES")
    other |> element("#publish-#{draft.id}") |> render_click()

    assert render(other) =~ "Version 2 is in force"
    assert has_element?(other, "#in-force", "Version 2")
    assert has_element?(other, "#in-force-review_above_amount_minor", "EUR 30,000.00")
    assert has_element?(other, "#version-#{ctx.first.id}", "retired")

    assert_enqueued(
      worker: Fides.Orchestration.Reevaluation,
      args: %{country_code: "ES", policy_version_id: draft.id}
    )
  end

  test "refuses thresholds that make no sense, by threshold or as a whole", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/backoffice/policies?country=ES")

    view
    |> form("#propose-form", policy: %{countersign_above_minor: "abc", history_window_days: "-3"})
    |> render_submit()

    assert has_element?(view, "#policy_countersign_above_minor-field", "must be an amount")
    assert has_element?(view, "#policy_history_window_days-field", "cannot be negative")
    assert versions("ES") |> Enum.map(& &1.version) == [1]

    # Portugal's bands must stay in order: the country's own check says so
    {:ok, view, _html} = live(ctx.conn, ~p"/backoffice/policies?country=PT")

    view
    |> form("#propose-form", policy: %{approve_max_income_multiple: "9"})
    |> render_submit()

    assert has_element?(
             view,
             "#propose-form",
             "approve_max_income_multiple cannot be above review_max_income_multiple"
           )

    assert versions("PT") |> Enum.map(& &1.version) == [1]
  end

  test "analysts and auditors read, and nothing more", ctx do
    for conn <- [ctx.analyst_conn, ctx.auditor_conn] do
      {:ok, view, _html} = live(conn, ~p"/backoffice/policies?country=ES")
      assert has_element?(view, "#in-force", "Version 1")
      assert has_element?(view, "#version-#{ctx.first.id}")
      refute has_element?(view, "#propose-form")
    end

    {:ok, view, _html} = live(ctx.auditor_conn, ~p"/backoffice/policies?country=MX")
    assert has_element?(view, "#in-force", "No version is in force")
  end
end
