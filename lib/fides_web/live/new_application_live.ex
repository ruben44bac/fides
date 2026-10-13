defmodule FidesWeb.NewApplicationLive do
  @moduledoc """
  Submits an application from the backoffice through the same action as the API: the
  holder is found or created from their document and data, their consent is recorded,
  and the application starts in submitted for the agents to work. Only analysts
  submit, and only in their countries. Each error shows next to the field that caused
  it, as the form is typed and when the action refuses it.
  """

  use FidesWeb, :live_view

  alias Fides.Platform.Actor
  alias FidesWeb.ApplicationForm

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    countries = scope.user |> Actor.countries([:analyst]) |> Enum.sort()

    {:ok,
     socket
     |> assign(
       page_title: "New application",
       countries: countries,
       catalog: catalog(countries, scope.user),
       consent_version: Fides.Identity.consent_text_version()
     )
     |> assign_form(%{"country" => List.first(countries), "consent" => "false"}, [])}
  end

  # The currency and the document types of each country the actor submits in
  defp catalog(countries, actor) do
    currencies = Map.new(Fides.Countries.list_countries!(), &{&1.code, &1.currency})

    Map.new(countries, fn country ->
      types =
        Fides.Identity.list_document_types!(tenant: country, actor: actor)
        |> Enum.filter(& &1.active)
        |> Enum.map(& &1.code)
        |> Enum.sort()

      {country, %{currency: Map.fetch!(currencies, country), document_types: types}}
    end)
  end

  @impl true
  def handle_event("validate", %{"application" => params}, socket) do
    params = another_country(params, socket.assigns.country)

    errors =
      case ApplicationForm.cast(params, socket.assigns.catalog, socket.assigns.consent_version) do
        {:ok, _country, _submission} -> []
        {:error, errors} -> errors
      end

    {:noreply, assign_form(socket, params, errors)}
  end

  def handle_event("save", %{"application" => params}, socket) do
    %{catalog: catalog, consent_version: version, current_scope: scope} = socket.assigns

    with {:ok, country, submission} <- ApplicationForm.cast(params, catalog, version),
         {:ok, application} <-
           Fides.Origination.submit_application(submission, tenant: country, actor: scope.user) do
      {:noreply,
       socket
       |> put_flash(:info, "Application submitted. The agents take it from here.")
       |> push_navigate(to: ~p"/backoffice/applications/#{application.id}")}
    else
      {:error, errors} when is_list(errors) ->
        {:noreply, assign_form(socket, params, errors)}

      {:error, %Ash.Error.Forbidden{}} ->
        {:noreply, put_flash(socket, :error, "You may not submit applications in that country.")}

      {:error, error} ->
        {:noreply, assign_form(socket, params, ApplicationForm.errors_from(error))}
    end
  end

  # Another country has other documents: the type chosen for the previous one goes
  defp another_country(%{"country" => country} = params, country), do: params
  defp another_country(params, _previous), do: Map.put(params, "document_type", "")

  defp assign_form(socket, params, errors) do
    country = params["country"]
    entry = Map.get(socket.assigns.catalog, country)

    assign(socket,
      form: to_form(params, as: :application, errors: errors),
      country: country,
      currency: entry && entry.currency,
      document_types: (entry && entry.document_types) || [],
      needed: ApplicationForm.needed(country, params["document_type"]),
      holder_errors: for({:holder, error} <- errors, do: translate_error(error))
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={:inbox}>
      <div class="mx-auto max-w-3xl space-y-6">
        <.link
          navigate={~p"/backoffice"}
          class="inline-flex items-center gap-1 text-sm text-zinc-500 transition-colors hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-white"
        >
          <.icon name="hero-arrow-left-mini" class="size-4" /> Inbox
        </.link>

        <.page_header
          title="New application"
          subtitle="The same action and checks as the API: the holder is found or created, their consent recorded, and the agents take it from there."
        />

        <.panel :if={@countries == []}>
          <.empty_state
            id="no-analyst-scope"
            icon="hero-lock-closed"
            title="Only analysts submit applications"
            text="None of your scopes is an analyst's, so there is no country to submit in."
          />
        </.panel>

        <.form
          :if={@countries != []}
          for={@form}
          id="application-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-6"
        >
          <.panel>
            <.panel_header
              title="Terms"
              subtitle="Amounts in the country's currency, cents after a dot or a comma."
            />
            <div class="grid gap-4 px-5 py-4 sm:grid-cols-3">
              <.field field={@form[:country]} type="select" label="Country" options={@countries} />
              <.field
                field={@form[:amount]}
                label={"Amount (#{@currency})"}
                inputmode="decimal"
                placeholder="25000.00"
              />
              <.field
                field={@form[:monthly_income]}
                label={"Monthly income (#{@currency})"}
                inputmode="decimal"
                placeholder="2500.00"
              />
            </div>
          </.panel>

          <.panel>
            <.panel_header
              title="Holder"
              subtitle="Their document is checked against their data; some documents encode the birth date or the sex."
            />
            <div
              :if={@holder_errors != []}
              id="holder-errors"
              class="mx-5 mt-4 rounded-lg bg-rose-50 px-3 py-2 text-sm text-rose-700 dark:bg-rose-500/10 dark:text-rose-300"
            >
              <p :for={error <- @holder_errors}>The holder {error}.</p>
            </div>
            <div class="grid gap-4 px-5 py-4 sm:grid-cols-2">
              <.field field={@form[:given_names]} label="Given names" autocomplete="off" />
              <.field field={@form[:first_surname]} label="First surname" autocomplete="off" />
              <.field
                field={@form[:second_surname]}
                label="Second surname (optional)"
                autocomplete="off"
              />
              <.field
                field={@form[:document_type]}
                type="select"
                label="Document type"
                prompt="Choose a document"
                options={@document_types}
              />
              <.field field={@form[:document]} label="Document" autocomplete="off" />
              <.field field={@form[:email]} type="email" label="Contact email" autocomplete="off" />
              <.field
                :if={:birth_date in @needed}
                field={@form[:birth_date]}
                type="date"
                label="Birth date"
              />
              <.field
                :if={:sex in @needed}
                field={@form[:sex]}
                type="select"
                label="Sex, as the document encodes it"
                prompt="Choose"
                options={[{"Female", "female"}, {"Male", "male"}]}
              />
            </div>
          </.panel>

          <.panel class="flex flex-wrap items-center justify-between gap-4 px-5 py-4">
            <.field
              field={@form[:consent]}
              type="checkbox"
              label={"The holder accepted the data processing text, version #{@consent_version}."}
              class="max-w-md"
            />
            <.action type="submit" variant="primary" phx-disable-with="Submitting…">
              <.icon name="hero-paper-airplane-mini" class="size-4" /> Submit the application
            </.action>
          </.panel>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
