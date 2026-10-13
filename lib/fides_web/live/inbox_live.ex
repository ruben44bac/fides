defmodule FidesWeb.InboxLive do
  @moduledoc """
  The applications of the countries where the staff user works, newest first, a page
  at a time, narrowed by country and state. Every change to an application in those
  countries reaches the screen as it happens.
  """

  use FidesWeb, :live_view

  alias Fides.Platform.ChangeListener
  alias FidesWeb.Format
  alias FidesWeb.StaffScope

  @limit 25

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      for country <- scope.countries,
          do: Phoenix.PubSub.subscribe(Fides.PubSub, ChangeListener.topic(country))
    end

    {:ok,
     socket
     |> assign(page_title: "Inbox", states: Fides.Origination.states())
     |> stream_configure(:applications, dom_id: &"application-#{&1.id}")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = filters(params, socket.assigns.current_scope)

    {:noreply,
     socket
     |> assign(filters: filters, form: to_form(form_values(filters), as: :filters))
     |> load()}
  end

  @impl true
  def handle_event("filter", %{"filters" => values}, socket) do
    params =
      values
      |> Map.take(["country", "state"])
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/backoffice?#{params}")}
  end

  # A change in one of the countries shown: the page is read again
  @impl true
  def handle_info({:application_changed, _change}, socket), do: {:noreply, load(socket)}

  defp filters(params, %StaffScope{countries: countries}) do
    %{
      country: if(params["country"] in countries, do: params["country"]),
      state: state(params["state"]),
      after: params["after"],
      limit: limit(params["limit"])
    }
  end

  defp state(nil), do: nil

  defp state(name) do
    Enum.find(Fides.Origination.states(), &(Atom.to_string(&1) == name))
  end

  defp limit(nil), do: @limit

  defp limit(value) do
    case Integer.parse(value) do
      {limit, ""} when limit in 1..100 -> limit
      _other -> @limit
    end
  end

  defp form_values(filters),
    do: %{
      "country" => filters.country || "",
      "state" => filters.state && Atom.to_string(filters.state)
    }

  defp load(socket) do
    %{filters: filters, current_scope: scope} = socket.assigns

    case Fides.Origination.inbox(filters, actor: scope.user) do
      {:ok, page} ->
        next = if page.more?, do: Ash.Resource.get_metadata(List.last(page.results), :keyset)

        socket
        |> stream(:applications, page.results, reset: true)
        |> assign(empty?: page.results == [], next: next_params(filters, next))

      {:error, _error} ->
        socket
        |> put_flash(:error, "The applications could not be read.")
        |> stream(:applications, [], reset: true)
        |> assign(empty?: true, next: nil)
    end
  end

  defp next_params(_filters, nil), do: nil

  defp next_params(filters, cursor) do
    %{after: cursor, limit: filters.limit}
    |> Map.merge(if(filters.country, do: %{country: filters.country}, else: %{}))
    |> Map.merge(if(filters.state, do: %{state: filters.state}, else: %{}))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={:inbox}>
      <div class="space-y-6">
        <.page_header
          title="Inbox"
          subtitle={"Applications in #{Enum.join(@current_scope.countries, ", ")}, newest first."}
        >
          <:actions>
            <.live_dot />
          </:actions>
        </.page_header>

        <.panel>
          <.form
            for={@form}
            id="inbox-filters"
            phx-change="filter"
            class="flex flex-wrap items-end gap-3 border-b border-zinc-200 px-5 py-4 dark:border-zinc-800"
          >
            <.field
              field={@form[:country]}
              type="select"
              label="Country"
              prompt="All countries"
              options={@current_scope.countries}
              class="w-44"
            />
            <.field
              field={@form[:state]}
              type="select"
              label="State"
              prompt="All states"
              options={Enum.map(@states, &{Format.state(&1), &1})}
              class="w-52"
            />
            <p class="ml-auto hidden text-xs text-zinc-500 sm:block dark:text-zinc-400">
              Each row updates as the application moves.
            </p>
          </.form>

          <div class="overflow-x-auto">
            <table class="w-full text-sm">
              <thead class="text-left text-[11px] font-medium uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
                <tr>
                  <th class="px-5 py-3">Application</th>
                  <th class="px-5 py-3">Country</th>
                  <th class="px-5 py-3">State</th>
                  <th class="px-5 py-3 text-right">Amount</th>
                  <th class="px-5 py-3 text-right">Monthly income</th>
                  <th class="px-5 py-3 text-right">Rev.</th>
                  <th class="px-5 py-3 text-right">Submitted</th>
                </tr>
              </thead>
              <tbody
                id="applications"
                phx-update="stream"
                class="divide-y divide-zinc-100 dark:divide-zinc-800"
              >
                <tr id="applications-empty" class="hidden only:table-row">
                  <td colspan="7">
                    <.empty_state
                      title="No applications here yet"
                      text="New applications appear the moment they arrive, and move as the agents and your colleagues work on them."
                    />
                  </td>
                </tr>
                <tr
                  :for={{id, application} <- @streams.applications}
                  id={id}
                  class="cursor-pointer transition-colors hover:bg-zinc-50 dark:hover:bg-zinc-800/50"
                  phx-click={JS.navigate(~p"/backoffice/applications/#{application.id}")}
                >
                  <td class="px-5 py-3">
                    <.link
                      navigate={~p"/backoffice/applications/#{application.id}"}
                      class="font-mono text-xs font-medium text-orange-700 hover:underline dark:text-orange-300"
                    >
                      {Format.short_id(application.id)}
                    </.link>
                  </td>
                  <td class="px-5 py-3">
                    <.tag>{application.country_code}</.tag>
                  </td>
                  <td class="px-5 py-3"><.state_badge state={application.state} /></td>
                  <td class="px-5 py-3 text-right font-medium tabular-nums">
                    {Format.amount(application.amount_minor, application.currency)}
                  </td>
                  <td class="px-5 py-3 text-right tabular-nums text-zinc-600 dark:text-zinc-400">
                    {Format.amount(application.monthly_income_minor, application.currency)}
                  </td>
                  <td class="px-5 py-3 text-right tabular-nums text-zinc-600 dark:text-zinc-400">
                    {application.revision}
                  </td>
                  <td
                    class="px-5 py-3 text-right text-zinc-600 dark:text-zinc-400"
                    title={Format.moment(application.submitted_at)}
                  >
                    {Format.relative(application.submitted_at)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div
            :if={@next}
            class="flex justify-end border-t border-zinc-200 px-5 py-3 dark:border-zinc-800"
          >
            <.action id="next-page" patch={~p"/backoffice?#{@next}"}>
              Older applications <.icon name="hero-arrow-right-mini" class="size-4" />
            </.action>
          </div>
        </.panel>
      </div>
    </Layouts.app>
    """
  end
end
