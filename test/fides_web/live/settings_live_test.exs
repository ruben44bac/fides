defmodule FidesWeb.SettingsLiveTest do
  use FidesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fides.Factory

  setup %{conn: conn} do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    {analyst, secret} = Factory.staff_user()
    Factory.scope(analyst, "ES", :analyst, admin)

    %{conn: staff_session(conn, Fides.Accounts.load_actor(analyst), secret), analyst: analyst}
  end

  test "shows the account, the theme switch and the way out", ctx do
    {:ok, view, html} = live(ctx.conn, ~p"/backoffice/settings")

    assert html =~ to_string(ctx.analyst.email)
    assert has_element?(view, "#account-scope", "ES")
    assert has_element?(view, "#theme-switch button[data-phx-theme=dark]")
    assert has_element?(view, "#sign-out[data-method=delete]")
  end

  test "the menu leads to the inbox and the settings, and folds", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/backoffice/settings")

    assert has_element?(view, "#sidebar a[href='/backoffice']", "Inbox")
    assert has_element?(view, "#sidebar a[aria-current=page]", "Settings")
    assert has_element?(view, "#sidebar-toggle")
  end

  test "needs a signed-in staff user", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/backoffice/sign-in"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/backoffice/settings")

    _ = conn
  end
end
