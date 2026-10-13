defmodule FidesWeb.InboxLiveTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use FidesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fides.Factory
  alias Fides.Origination

  setup %{conn: conn} do
    Factory.reference_data()
    {admin, admin_secret} = Factory.staff_user(global_role: :admin)
    {analyst, secret} = Factory.staff_user()
    Factory.scope(analyst, "ES", :analyst, admin)
    analyst = Fides.Accounts.load_actor(analyst)
    mexican = Factory.scoped_staff("MX", :analyst, admin)

    %{
      conn: staff_session(conn, analyst, secret),
      admin_conn: staff_session(conn, admin, admin_secret),
      analyst: analyst,
      mexican: mexican
    }
  end

  defp submit(submission, country, analyst) do
    Factory.insert(fn ->
      Origination.submit_application!(submission, tenant: country, actor: analyst)
    end)
  end

  defp row(application), do: "#application-#{application.id}"

  test "lists the applications of the actor's countries, newest first, and only those", ctx do
    older = submit(Factory.submission(), "ES", ctx.analyst)
    newer = submit(Factory.submission(), "ES", ctx.analyst)
    foreign = submit(Factory.mexican_submission(), "MX", ctx.mexican)

    {:ok, view, html} = live(ctx.conn, ~p"/backoffice")

    assert html =~ "Inbox"
    assert has_element?(view, row(newer))
    assert has_element?(view, row(older))
    refute has_element?(view, row(foreign))

    # The newer one comes first
    assert :binary.match(html, newer.id) < :binary.match(html, older.id)

    {:ok, view, _html} = live(ctx.admin_conn, ~p"/backoffice")
    assert has_element?(view, row(foreign))
    assert has_element?(view, row(older))
  end

  test "filters by country and state", ctx do
    submitted = submit(Factory.submission(), "ES", ctx.analyst)

    cancelled =
      Factory.insert(fn ->
        Factory.submission()
        |> Origination.submit_application!(tenant: "ES", actor: ctx.analyst)
        |> Origination.transition_application!(:cancelled, 1, %{reason: "withdrew"},
          tenant: "ES",
          actor: ctx.analyst
        )
      end)

    {:ok, view, _html} = live(ctx.conn, ~p"/backoffice")

    view
    |> element("#inbox-filters")
    |> render_change(%{filters: %{state: "cancelled", country: "ES"}})

    assert_patch(view, ~p"/backoffice?country=ES&state=cancelled")
    assert has_element?(view, row(cancelled))
    refute has_element?(view, row(submitted))

    # A country outside the scope is ignored
    {:ok, view, _html} = live(ctx.conn, ~p"/backoffice?country=MX")
    assert has_element?(view, row(submitted))
  end

  test "pages with keyset, and shows an empty state", ctx do
    [first, second, third] =
      for _application <- 1..3, do: submit(Factory.submission(), "ES", ctx.analyst)

    {:ok, view, _html} = live(ctx.conn, ~p"/backoffice?limit=2")
    assert has_element?(view, row(third))
    assert has_element?(view, row(second))
    refute has_element?(view, row(first))

    view |> element("#next-page") |> render_click()
    assert has_element?(view, row(first))
    refute has_element?(view, row(third))
    refute has_element?(view, "#next-page")

    {:ok, view, _html} = live(ctx.conn, ~p"/backoffice?state=approved")
    assert has_element?(view, "#applications-empty")
  end

  test "a change to an application in the actor's countries shows up without reloading", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/backoffice")
    assert has_element?(view, "#applications-empty")

    application = submit(Factory.submission(), "ES", ctx.analyst)

    # The database's notification, as the listener passes it on
    Fides.Platform.ChangeListener.broadcast(
      Jason.encode!(%{
        id: application.id,
        country_code: "ES",
        state: "submitted",
        lock_version: 1
      }),
      Fides.PubSub
    )

    assert render(view) =~ application.id
    assert has_element?(view, row(application))

    # A change in another country is not even heard
    Phoenix.PubSub.broadcast(Fides.PubSub, "applications:MX", {:application_changed, %{}})
    assert has_element?(view, row(application))
  end

  test "shows who is signed in and where they work", ctx do
    {:ok, _view, html} = live(ctx.conn, ~p"/backoffice")
    assert html =~ to_string(ctx.analyst.email)
    assert html =~ ">ES<"
  end
end
