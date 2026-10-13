defmodule FidesWeb.NewApplicationLiveTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use FidesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fides.Factory
  alias Fides.Origination
  alias Fides.Platform.SystemActor

  @typed %{
    country: "ES",
    amount: "25000",
    monthly_income: "2500.50",
    given_names: "Lucía",
    first_surname: "Martín",
    document_type: "DNI",
    document: "12345678Z",
    email: "lucia@example.com",
    consent: "true"
  }

  setup %{conn: conn} do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    {auditor, auditor_secret} = Factory.staff_user(global_role: :auditor)

    {analyst, secret} = Factory.staff_user()
    Factory.scope(analyst, "ES", :analyst, admin)
    Factory.scope(analyst, "MX", :analyst, admin)
    analyst = Fides.Accounts.load_actor(analyst)

    %{
      conn: staff_session(conn, analyst, secret),
      auditor_conn: staff_session(conn, auditor, auditor_secret),
      analyst: analyst
    }
  end

  defp submit(view, typed) do
    view |> form("#application-form", application: typed) |> render_submit()
  end

  test "submits an application through the same action as the API, and opens it", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/backoffice/applications/new")

    assert {:error, {:live_redirect, %{to: to}}} = redirect = submit(view, @typed)

    assert [application] = Origination.list_applications!(tenant: "ES", authorize?: false)
    assert to == "/backoffice/applications/#{application.id}"

    {:ok, _detail, html} = follow_redirect(redirect, ctx.conn)
    assert html =~ "Application submitted"

    assert %{
             state: :submitted,
             revision: 1,
             channel: :form,
             currency: "EUR",
             amount_minor: 2_500_000,
             monthly_income_minor: 250_050
           } = application

    assert [consent] = Fides.Identity.list_consents!(tenant: "ES", actor: SystemActor.new(:test))
    assert %{text_version: "2026-10", channel: :form} = consent
    assert consent.person_id == application.person_id
  end

  test "shows each error next to its field, and the holder's refusal with the holder", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/backoffice/applications/new")

    submit(view, %{@typed | document: "12345678A", email: "", consent: "false"})
    assert has_element?(view, "#application_document-field", "invalid check character")
    assert has_element?(view, "#application_email-field", "is required")
    assert has_element?(view, "#application_consent-field", "must be confirmed")
    assert Origination.list_applications!(tenant: "ES", authorize?: false) == []

    # The action refuses a second application for a holder with one in progress
    Factory.insert(fn ->
      Origination.submit_application!(Factory.submission(holder: Factory.holder(12_345_678)),
        tenant: "ES",
        actor: ctx.analyst
      )
    end)

    submit(view, @typed)
    assert has_element?(view, "#holder-errors", "already has an application in progress")
    assert [_one] = Origination.list_applications!(tenant: "ES", authorize?: false)
  end

  test "says what is wrong as the form is typed, only for the fields touched", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/backoffice/applications/new")

    # The browser marks the inputs not touched yet, as LiveView does
    view
    |> form("#application-form", application: %{amount: "abc"})
    |> render_change(%{"application" => %{"_unused_email" => ""}})

    assert has_element?(view, "#application_amount-field", "must be an amount")
    refute has_element?(view, "#application_email-field", "is required")
  end

  test "asks for the data the country's document is checked against", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/backoffice/applications/new")
    refute has_element?(view, "#application_birth_date")

    view
    |> form("#application-form", application: %{country: "MX"})
    |> render_change()

    assert has_element?(view, "#application_amount-field", "MXN")
    assert has_element?(view, "#application_document_type option[value=CURP]")
    refute has_element?(view, "#application_document_type option[value=DNI]")

    view
    |> form("#application-form", application: %{country: "MX", document_type: "CURP"})
    |> render_change()

    assert has_element?(view, "#application_birth_date")
    refute has_element?(view, "#application_sex")
  end

  test "only analysts submit, and the inbox offers it to them alone", ctx do
    {:ok, view, _html} = live(ctx.auditor_conn, ~p"/backoffice/applications/new")
    assert has_element?(view, "#no-analyst-scope")
    refute has_element?(view, "#application-form")

    {:ok, inbox, _html} = live(ctx.auditor_conn, ~p"/backoffice")
    refute has_element?(inbox, "#new-application")

    {:ok, inbox, _html} = live(ctx.conn, ~p"/backoffice")
    assert has_element?(inbox, "#new-application")
  end
end
