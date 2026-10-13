defmodule FidesWeb.ApplicationHolderLiveTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use FidesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fides.Factory
  alias Fides.Identity
  alias Fides.Origination

  @holder %{
    document_type: "DNI",
    document: "12345678Z",
    given_names: "Zoila",
    first_surname: "Quintana",
    second_surname: "Sotomayor",
    email: "zoila.quintana@example.com"
  }

  setup %{conn: conn} do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    {auditor, auditor_secret} = Factory.staff_user(global_role: :auditor)

    {analyst, secret} = Factory.staff_user()
    Factory.scope(analyst, "ES", :analyst, admin)
    analyst = Fides.Accounts.load_actor(analyst)

    application =
      Factory.insert(fn ->
        Origination.submit_application!(Factory.submission(holder: @holder),
          tenant: "ES",
          actor: analyst
        )
      end)

    %{
      conn: staff_session(conn, analyst, secret),
      auditor_conn: staff_session(conn, auditor, auditor_secret),
      analyst: analyst,
      path: ~p"/backoffice/applications/#{application.id}",
      application: application
    }
  end

  defp hidden?(html) do
    not (html =~ "12345678Z" or html =~ "Zoila" or html =~ "Quintana" or
           html =~ "zoila.quintana@example.com")
  end

  test "keeps the holder's data hidden until revealed for a reason, and logs each look", ctx do
    {:ok, view, html} = live(ctx.conn, ctx.path)
    assert hidden?(html)
    assert has_element?(view, "#holder-document", "••••")
    refute has_element?(view, "#pii-accesses")

    # Without a reason, nothing is revealed and nothing is logged
    view |> element("#reveal-document") |> render_click()
    view |> form("#reveal-form", reveal: %{reason: "  "}) |> render_submit()
    assert has_element?(view, "#reveal-form", "is required")
    assert hidden?(render(view))
    assert {:ok, []} = Identity.pii_accesses("ES", ctx.application.person_id, ctx.analyst)

    view
    |> form("#reveal-form", reveal: %{reason: "The holder called about the amount"})
    |> render_submit()

    assert has_element?(view, "#holder-document", "12345678Z")
    refute has_element?(view, "#reveal-form")
    assert has_element?(view, "#pii-accesses li", "document")
    assert has_element?(view, "#pii-accesses li", "The holder called about the amount")
    assert has_element?(view, "#pii-accesses li", "you")

    {:ok, [access]} = Identity.pii_accesses("ES", ctx.application.person_id, ctx.analyst)
    assert %{field: :document, reason: "The holder called about the amount"} = access
    assert access.accessed_by == ctx.analyst.id

    # The name reads as one line; hiding the document leaves the log as it is
    view |> element("#reveal-name") |> render_click()
    view |> form("#reveal-form", reveal: %{reason: "Identity check"}) |> render_submit()
    assert has_element?(view, "#holder-name", "Zoila Quintana Sotomayor")

    view |> element("#hide-document") |> render_click()
    assert has_element?(view, "#holder-document", "••••")
    refute render(view) =~ "12345678Z"

    assert {:ok, [_name, _document]} =
             Identity.pii_accesses("ES", ctx.application.person_id, ctx.analyst)
  end

  test "an auditor sees the access log, but neither the data nor a way to reveal it", ctx do
    {:ok, _revealed} =
      Fides.Platform.AuditContext.run(
        [actor: "staff_user:" <> ctx.analyst.id, reason: "backoffice"],
        fn ->
          Identity.reveal("ES", ctx.application.person_id, :email, "to call back", ctx.analyst)
        end
      )

    {:ok, view, html} = live(ctx.auditor_conn, ctx.path)
    assert hidden?(html)
    refute has_element?(view, "#reveal-document")
    refute has_element?(view, "#reveal-email")
    assert has_element?(view, "#pii-accesses li", "email")
    assert has_element?(view, "#pii-accesses li", "to call back")
    assert has_element?(view, "#pii-accesses li", "staff ·")
  end
end
