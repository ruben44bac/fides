defmodule FidesWeb.ApplicationLive do
  @moduledoc """
  One application, whole: its terms and their revisions, the bank data behind it,
  each decision with the rules that changed since the one before, what the agents
  found and did, and the story the evidence tells. The screen follows the application
  as it moves. An application outside the staff user's countries does not exist here.

  From here the staff user makes the moves the life cycle allows them right now, each
  with a reason the evidence keeps. A move on a version that is no longer current does
  not happen: the screen says so and offers to read the application again, keeping
  what was written.

  The holder's personal data stays hidden. The staff of the holder's country reveal one
  field at a time, for a reason that goes to the access log with who looked and when;
  what was revealed lives only on this screen, until hidden or left.
  """

  use FidesWeb, :live_view

  alias Fides.Origination.TransitionNotAllowed
  alias Fides.Platform.ChangeListener
  alias FidesWeb.Format
  alias FidesWeb.StaffScope

  @personal_fields [:name, :document, :email]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       subscribed: nil,
       move: nil,
       move_form: nil,
       conflict?: false,
       revealed: %{},
       revealing: nil,
       reveal_form: nil
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket), do: {:noreply, load(socket, id)}

  # Picking a field opens the form for the reason to see it; picking none closes it
  @impl true
  def handle_event("reveal", params, socket) do
    case Enum.find(@personal_fields, &(Atom.to_string(&1) == params["field"])) do
      nil -> {:noreply, assign(socket, revealing: nil, reveal_form: nil)}
      field -> {:noreply, assign(socket, revealing: field, reveal_form: reveal_form(""))}
    end
  end

  def handle_event("draft_reveal", %{"reveal" => %{"reason" => reason}}, socket),
    do: {:noreply, assign(socket, :reveal_form, reveal_form(reason))}

  def handle_event("confirm_reveal", %{"reveal" => %{"reason" => reason}}, socket) do
    %{application: application, current_scope: scope, revealing: field} = socket.assigns

    application.country_code
    |> Fides.Identity.reveal(application.person_id, field, reason, scope.user)
    |> case do
      {:ok, %{value: value}} ->
        {:noreply,
         socket
         |> assign(
           revealed: Map.put(socket.assigns.revealed, field, value),
           revealing: nil,
           reveal_form: nil
         )
         |> assign(:accesses, accesses(application, scope.user))}

      {:error, %Ash.Error.Forbidden{}} ->
        {:noreply,
         socket
         |> assign(revealing: nil, reveal_form: nil)
         |> put_flash(:error, "You may not reveal this holder's data.")}

      {:error, error} ->
        {:noreply, assign(socket, :reveal_form, reveal_form(reason, reveal_errors(error)))}
    end
  end

  def handle_event("hide", %{"field" => field}, socket) do
    revealed =
      Map.reject(socket.assigns.revealed, fn {name, _} -> Atom.to_string(name) == field end)

    {:noreply, assign(socket, :revealed, revealed)}
  end

  # Choosing a move opens the form for its reason; choosing again changes the move and
  # keeps the reason, and choosing none closes it
  def handle_event("choose", params, socket) do
    case Enum.find(socket.assigns.moves, &(Atom.to_string(&1) == params["to"])) do
      nil -> {:noreply, assign(socket, move: nil, move_form: nil, conflict?: false)}
      to -> {:noreply, assign(socket, move: to, move_form: move_form(reason(socket)))}
    end
  end

  def handle_event("draft", %{"move" => %{"reason" => reason}}, socket),
    do: {:noreply, assign(socket, :move_form, move_form(reason))}

  def handle_event("move", %{"move" => %{"reason" => reason}}, socket) do
    %{application: application, current_scope: scope, move: to} = socket.assigns

    application
    |> Fides.Origination.transition_application(to, application.lock_version, %{reason: reason},
      tenant: application.country_code,
      actor: scope.user
    )
    |> case do
      {:ok, _moved} ->
        {:noreply,
         socket
         |> assign(move: nil, move_form: nil, conflict?: false)
         |> put_flash(:info, "Moved to #{Format.label(to)}.")
         |> load(application.id)}

      {:error, error} ->
        {:noreply, refused(socket, error, reason)}
    end
  end

  def handle_event("reload", _params, socket),
    do: {:noreply, socket |> assign(:conflict?, false) |> load(socket.assigns.application.id)}

  # The application itself changed: everything is read again
  @impl true
  def handle_info(
        {:application_changed, %{id: id}},
        %{assigns: %{application: %{id: id}}} = socket
      ),
      do: {:noreply, load(socket, id)}

  def handle_info({:application_changed, _other}, socket), do: {:noreply, socket}

  defp load(socket, id) do
    scope = socket.assigns.current_scope

    case Fides.Origination.find_application(id, actor: scope.user) do
      {:ok, %{} = application} ->
        socket
        |> subscribe(application.country_code)
        |> assign(
          application: application,
          moves: Fides.Origination.available_moves(application, scope.user),
          may_reveal?:
            StaffScope.role(scope, application.country_code) in [:analyst, :risk_manager],
          page_title: "Application #{Format.short_id(application.id)}"
        )
        |> assign(evidence(application, scope.user))
        |> reconcile_move()

      _missing ->
        socket
        |> put_flash(:error, "That application does not exist, or is outside your countries.")
        |> push_navigate(to: ~p"/backoffice")
    end
  end

  # Every change in the application's country reaches the screen; it keeps the ones to
  # this application
  defp subscribe(%{assigns: %{subscribed: country}} = socket, country), do: socket

  defp subscribe(socket, country) do
    if connected?(socket) do
      if previous = socket.assigns.subscribed,
        do: Phoenix.PubSub.unsubscribe(Fides.PubSub, ChangeListener.topic(previous))

      Phoenix.PubSub.subscribe(Fides.PubSub, ChangeListener.topic(country))
    end

    assign(socket, :subscribed, country)
  end

  defp evidence(application, actor) do
    %{country_code: country, id: id} = application
    decisions = read!(Fides.Risk.decisions(country, id, actor))
    by_id = Map.new(decisions, &{&1.id, &1})

    %{
      revisions: read!(Fides.Origination.revisions(country, id, actor)),
      profiles: read!(Fides.Banking.profiles(country, id, actor)),
      exchanges: read!(Fides.Banking.exchanges(country, id, actor)),
      providers: names(Fides.Banking.list_bank_providers!(tenant: country, actor: actor), :name),
      decisions:
        Enum.map(decisions, fn decision ->
          %{
            record: decision,
            changed: Fides.Risk.changed_rules(decision, by_id[decision.replaces_id])
          }
        end),
      policies: names(Fides.Risk.list_policy_versions!(tenant: country, actor: actor), :version),
      facts: read!(Fides.Orchestration.case_fact_history(country, id, actor)),
      runs: read!(Fides.Orchestration.agent_runs(country, id, actor)),
      accesses: accesses(application, actor),
      timeline: id |> Fides.Audit.timeline() |> Enum.reverse()
    }
  end

  defp accesses(application, actor),
    do: read!(Fides.Identity.pii_accesses(application.country_code, application.person_id, actor))

  defp reveal_form(reason, errors \\ []),
    do: to_form(%{"reason" => reason}, as: :reveal, errors: errors)

  # The form has one field, so whatever was refused is said next to it
  defp reveal_errors(%{errors: errors}) when is_list(errors),
    do: Enum.map(errors, &{:reason, {reveal_message(&1), []}})

  defp reveal_errors(error), do: [reason: {message(error), []}]

  defp reveal_message(%Ash.Error.Changes.Required{}), do: "is required"
  defp reveal_message(error), do: message(error)

  defp read!({:ok, items}), do: items
  defp read!({:error, error}) when is_exception(error), do: raise(error)
  defp read!({:error, error}), do: raise("the evidence could not be read: #{inspect(error)}")

  defp names(records, field), do: Map.new(records, &{&1.id, Map.fetch!(&1, field)})

  # A move being prepared that the application no longer allows is said so, and what
  # was written stays
  defp reconcile_move(%{assigns: %{move: nil}} = socket), do: socket

  defp reconcile_move(%{assigns: %{move: move, moves: moves, application: application}} = socket) do
    if move in moves do
      socket
    else
      gone =
        {"is no longer possible: the application is now #{Format.label(application.state)}", []}

      assign(socket, :move_form, move_form(reason(socket), to: gone))
    end
  end

  defp reason(%{assigns: %{move_form: %{params: %{"reason" => reason}}}}), do: reason
  defp reason(_socket), do: ""

  defp move_form(reason, errors \\ []),
    do: to_form(%{"reason" => reason}, as: :move, errors: errors)

  # A move refused because the application changed offers to read it again; one refused
  # for another reason shows it next to what caused it
  defp refused(socket, %Ash.Error.Forbidden{}, reason),
    do: assign(socket, :move_form, move_form(reason, to: {"is not a move you may make", []}))

  defp refused(socket, %{errors: errors}, reason) when is_list(errors) do
    if Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) do
      assign(socket, conflict?: true, move_form: move_form(reason))
    else
      assign(socket, :move_form, move_form(reason, Enum.map(errors, &field_error/1)))
    end
  end

  defp refused(socket, error, reason),
    do: assign(socket, :move_form, move_form(reason, to: {message(error), []}))

  defp field_error(%Ash.Error.Changes.InvalidArgument{
         field: field,
         message: message,
         vars: vars
       }),
       do: {field, {message, vars || []}}

  defp field_error(%TransitionNotAllowed{} = error),
    do: {:to, {TransitionNotAllowed.summary(error), []}}

  defp field_error(error), do: {:to, {message(error), []}}

  defp message(error) when is_exception(error), do: Exception.message(error)
  defp message(error), do: inspect(error)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={:inbox}>
      <div class="space-y-6">
        <.link
          navigate={~p"/backoffice"}
          class="inline-flex items-center gap-1 text-sm text-zinc-500 transition-colors hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-white"
        >
          <.icon name="hero-arrow-left-mini" class="size-4" /> Inbox
        </.link>

        <.page_header
          title={"Application #{Format.short_id(@application.id)}"}
          subtitle={"#{@application.country_code} · submitted #{Format.moment(@application.submitted_at)} · revision #{@application.revision} · version #{@application.lock_version}"}
        >
          <:actions>
            <span id="application-state"><.state_badge state={@application.state} /></span>
            <.live_dot />
          </:actions>
        </.page_header>

        <div class="grid gap-6 xl:grid-cols-3">
          <div class="space-y-6 xl:col-span-2">
            <.terms application={@application} revisions={@revisions} policies={@policies} />
            <.holder
              application={@application}
              revealed={@revealed}
              revealing={@revealing}
              form={@reveal_form}
              may_reveal?={@may_reveal?}
              accesses={@accesses}
              user_id={@current_scope.user.id}
            />
            <.bank_data
              application={@application}
              profiles={@profiles}
              exchanges={@exchanges}
              providers={@providers}
            />
            <.decisions application={@application} decisions={@decisions} policies={@policies} />
            <.agents facts={@facts} runs={@runs} />
          </div>
          <div class="space-y-6">
            <.moves
              application={@application}
              moves={@moves}
              move={@move}
              form={@move_form}
              conflict?={@conflict?}
            />
            <.timeline entries={@timeline} currency={@application.currency} />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :application, :map, required: true
  attr :revisions, :list, required: true
  attr :policies, :map, required: true

  defp terms(assigns) do
    ~H"""
    <.panel id="terms">
      <.panel_header
        title="Terms"
        subtitle={"Revision #{@application.revision} is current; every correction adds one."}
      />
      <dl class="grid gap-4 px-5 py-4 sm:grid-cols-2 lg:grid-cols-4">
        <.kv label="Amount">
          <span class="tabular-nums">
            {Format.amount(@application.amount_minor, @application.currency)}
          </span>
        </.kv>
        <.kv label="Monthly income">
          <span class="tabular-nums">
            {Format.amount(@application.monthly_income_minor, @application.currency)}
          </span>
        </.kv>
        <.kv label="Channel">{@application.channel}</.kv>
        <.kv label="Policy version">
          {policy(@policies, @application.policy_version_id) || "not evaluated yet"}
        </.kv>
        <.kv :if={@application.previous_application_id} label="Retries">
          <.link
            navigate={~p"/backoffice/applications/#{@application.previous_application_id}"}
            class="font-mono text-xs text-orange-700 hover:underline dark:text-orange-300"
          >
            {Format.short_id(@application.previous_application_id)}
          </.link>
        </.kv>
      </dl>
      <table id="revisions" class="w-full border-t border-zinc-200 text-sm dark:border-zinc-800">
        <thead class="text-left text-[11px] font-medium uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
          <tr>
            <th class="px-5 py-2.5">Revision</th>
            <th class="px-5 py-2.5 text-right">Amount</th>
            <th class="px-5 py-2.5 text-right">Monthly income</th>
            <th class="px-5 py-2.5">Cause</th>
            <th class="px-5 py-2.5 text-right">Submitted</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-zinc-100 dark:divide-zinc-800">
          <tr
            :for={revision <- @revisions}
            id={"revision-#{revision.number}"}
            class={revision.number == @application.revision && "bg-orange-50/60 dark:bg-orange-500/5"}
          >
            <td class="px-5 py-2.5 font-medium">
              {revision.number}
              <.tag :if={revision.number == @application.revision} tone="amber" class="ml-1">
                current
              </.tag>
            </td>
            <td class="px-5 py-2.5 text-right tabular-nums">
              {Format.amount(revision.amount_minor, @application.currency)}
            </td>
            <td class="px-5 py-2.5 text-right tabular-nums">
              {Format.amount(revision.monthly_income_minor, @application.currency)}
            </td>
            <td class="px-5 py-2.5 text-zinc-600 dark:text-zinc-400">
              {Format.label(revision.cause)}
            </td>
            <td
              class="px-5 py-2.5 text-right text-zinc-600 dark:text-zinc-400"
              title={Format.instant(revision.submitted_at)}
            >
              {Format.relative(revision.submitted_at)}
            </td>
          </tr>
        </tbody>
      </table>
    </.panel>
    """
  end

  attr :application, :map, required: true
  attr :revealed, :map, required: true
  attr :revealing, :atom, default: nil
  attr :form, :any, default: nil
  attr :may_reveal?, :boolean, required: true
  attr :accesses, :list, required: true
  attr :user_id, :string, required: true

  defp holder(assigns) do
    assigns = assign(assigns, :fields, @personal_fields)

    ~H"""
    <.panel id="holder">
      <.panel_header
        title="Holder"
        subtitle="Personal data stays encrypted. Revealing a field asks for a reason, and the access log keeps who looked, at what, and why."
      >
        <:actions>
          <span class="font-mono text-xs text-zinc-500 dark:text-zinc-400" title="The holder's id">
            {Format.short_id(@application.person_id)}
          </span>
        </:actions>
      </.panel_header>
      <dl class="grid gap-4 px-5 py-4 sm:grid-cols-3">
        <.kv :for={field <- @fields} id={"holder-#{field}"} label={Format.label(field)}>
          <%= if Map.has_key?(@revealed, field) do %>
            <span class="break-all">{@revealed[field]}</span>
            <button
              type="button"
              id={"hide-#{field}"}
              phx-click="hide"
              phx-value-field={field}
              class="ml-2 text-xs text-zinc-500 hover:underline dark:text-zinc-400"
            >
              Hide
            </button>
          <% else %>
            <span class="tracking-widest text-zinc-400 dark:text-zinc-500">••••••</span>
            <button
              :if={@may_reveal?}
              type="button"
              id={"reveal-#{field}"}
              phx-click="reveal"
              phx-value-field={field}
              class="ml-2 text-xs font-medium text-orange-700 hover:underline dark:text-orange-300"
            >
              Reveal…
            </button>
          <% end %>
        </.kv>
      </dl>
      <.form
        :if={@revealing}
        for={@form}
        id="reveal-form"
        phx-change="draft_reveal"
        phx-submit="confirm_reveal"
        class="mx-5 mb-4 space-y-3 rounded-xl border border-zinc-200 bg-zinc-50/60 p-4 dark:border-zinc-700 dark:bg-zinc-800/40"
      >
        <p class="text-sm">
          Revealing the holder's <strong>{Format.label(@revealing)}</strong>.
          <span class="text-zinc-500 dark:text-zinc-400">
            Who, when and why go to the access log.
          </span>
        </p>
        <.field
          field={@form[:reason]}
          type="textarea"
          label="Reason"
          rows="2"
          placeholder="Why you need to see it"
        />
        <div class="flex flex-wrap gap-2">
          <.action type="submit" variant="primary" phx-disable-with="Revealing…">
            Reveal the {Format.label(@revealing)}
          </.action>
          <.action type="button" phx-click="reveal">Back</.action>
        </div>
      </.form>
      <div :if={@accesses != []} class="border-t border-zinc-200 dark:border-zinc-800">
        <h3 class="px-5 pt-4 text-xs font-medium uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
          Access log
        </h3>
        <ul id="pii-accesses" class="divide-y divide-zinc-100 px-5 dark:divide-zinc-800">
          <li
            :for={access <- @accesses}
            id={"access-#{access.id}"}
            class="flex flex-wrap items-baseline gap-x-3 gap-y-1 py-2.5 text-sm"
          >
            <span class="font-medium">{Format.label(access.field)}</span>
            <span class="text-zinc-600 dark:text-zinc-400">{access.reason}</span>
            <span class="ml-auto text-xs text-zinc-500 dark:text-zinc-400">
              {who(access.accessed_by, @user_id)} · {Format.instant(access.accessed_at)}
            </span>
          </li>
        </ul>
      </div>
    </.panel>
    """
  end

  attr :application, :map, required: true
  attr :profiles, :list, required: true
  attr :exchanges, :list, required: true
  attr :providers, :map, required: true

  defp bank_data(assigns) do
    assigns = assign(assigns, :latest, List.first(assigns.profiles))

    ~H"""
    <.panel id="bank-data">
      <.panel_header
        title="Bank data"
        subtitle="What the country's provider reported, normalized and masked. The answer itself is never kept."
      />
      <%= if @latest do %>
        <dl class="grid gap-4 px-5 py-4 sm:grid-cols-2 lg:grid-cols-4">
          <.kv label="Observed monthly income">
            <span class="tabular-nums">
              {Format.amount(@latest.observed_income_minor, @application.currency)}
            </span>
          </.kv>
          <.kv label="Total debt">
            <span class="tabular-nums">
              {Format.amount(@latest.total_debt_minor, @application.currency)}
            </span>
          </.kv>
          <.kv label="Score">
            <span class="tabular-nums">{@latest.score}</span>
            <span class="text-xs text-zinc-500 dark:text-zinc-400">/ 1000</span>
          </.kv>
          <.kv label="Months with income">
            <span class="tabular-nums">{@latest.income_months}</span>
            <span class="text-xs text-zinc-500 dark:text-zinc-400">of the last 6</span>
          </.kv>
          <.kv label="Account"><span class="font-mono">{@latest.account_masked}</span></.kv>
          <.kv label="Provider">{Map.get(@providers, @latest.provider_id, "unknown")}</.kv>
          <.kv label="Origin">{@latest.origin}</.kv>
          <.kv label="Fetched">
            <span title={Format.instant(@latest.inserted_at)}>{Format.relative(@latest.inserted_at)}</span>
          </.kv>
        </dl>
        <p
          :if={length(@profiles) > 1}
          class="px-5 pb-4 text-xs text-zinc-500 dark:text-zinc-400"
        >
          {length(@profiles) - 1} earlier {if length(@profiles) == 2, do: "profile", else: "profiles"} on record; the decisions name the one each used.
        </p>
      <% else %>
        <p class="px-5 py-4 text-sm text-zinc-500 dark:text-zinc-400">
          No bank data yet. The Banking agent asks the provider when the application
          reaches awaiting bank data.
        </p>
      <% end %>
      <table
        :if={@exchanges != []}
        id="exchanges"
        class="w-full border-t border-zinc-200 text-sm dark:border-zinc-800"
      >
        <thead class="text-left text-[11px] font-medium uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
          <tr>
            <th class="px-5 py-2.5">Call to the provider</th>
            <th class="px-5 py-2.5">Outcome</th>
            <th class="px-5 py-2.5 text-right">HTTP</th>
            <th class="px-5 py-2.5 text-right">Attempt</th>
            <th class="px-5 py-2.5 text-right">Took</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-zinc-100 dark:divide-zinc-800">
          <tr :for={exchange <- @exchanges} id={"exchange-#{exchange.id}"}>
            <td class="px-5 py-2.5">
              <span
                class="text-zinc-600 dark:text-zinc-400"
                title={Format.instant(exchange.inserted_at)}
              >
                {Format.relative(exchange.inserted_at)}
              </span>
              <span class="ml-1 text-xs text-zinc-500 dark:text-zinc-400">
                {Map.get(@providers, exchange.provider_id, "unknown provider")}
              </span>
            </td>
            <td class="px-5 py-2.5">
              <.tag tone={exchange_tone(exchange.status)}>{exchange.status}</.tag>
              <span :if={exchange.error} class="ml-2 text-xs text-rose-600 dark:text-rose-400">
                {exchange.error}
              </span>
            </td>
            <td class="px-5 py-2.5 text-right tabular-nums">{exchange.http_status || "—"}</td>
            <td class="px-5 py-2.5 text-right tabular-nums">{exchange.attempt}</td>
            <td class="px-5 py-2.5 text-right tabular-nums">
              {Format.duration(exchange.latency_ms)}
            </td>
          </tr>
        </tbody>
      </table>
    </.panel>
    """
  end

  attr :application, :map, required: true
  attr :decisions, :list, required: true
  attr :policies, :map, required: true

  defp decisions(assigns) do
    ~H"""
    <.panel id="decisions">
      <.panel_header
        title="Decisions"
        subtitle="Each one with what every rule said. A reevaluation marks the rules that changed their mind."
      />
      <p :if={@decisions == []} class="px-5 py-4 text-sm text-zinc-500 dark:text-zinc-400">
        No decision yet. Risk decides when the application reaches evaluating.
      </p>
      <div class="divide-y divide-zinc-200 dark:divide-zinc-800">
        <.decision
          :for={%{record: decision, changed: changed} <- @decisions}
          decision={decision}
          changed={changed}
          currency={@application.currency}
          policy={policy(@policies, decision.policy_version_id)}
        />
      </div>
    </.panel>
    """
  end

  attr :decision, :map, required: true
  attr :changed, :list, required: true
  attr :currency, :string, required: true
  attr :policy, :integer, default: nil

  defp decision(assigns) do
    ~H"""
    <article id={"decision-#{@decision.id}"} class="space-y-4 px-5 py-4">
      <div class="flex flex-wrap items-center gap-2 text-sm">
        <.tag tone={outcome_tone(@decision.outcome)} class="text-sm">{@decision.outcome}</.tag>
        <span class="text-zinc-600 dark:text-zinc-400">{Format.label(@decision.cause)}</span>
        <span :if={@policy} class="text-zinc-600 dark:text-zinc-400">· policy v{@policy}</span>
        <span class="ml-auto text-xs text-zinc-500 dark:text-zinc-400">
          {Format.instant(@decision.inserted_at)}
        </span>
      </div>
      <div :if={@decision.reason_codes != []} class="flex flex-wrap gap-1.5">
        <.tag :for={code <- @decision.reason_codes} tone={outcome_tone(@decision.outcome)}>
          {Format.label(code)}
        </.tag>
      </div>
      <table class="w-full text-sm">
        <thead class="text-left text-[11px] font-medium uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
          <tr>
            <th class="py-1.5 pr-4">Rule</th>
            <th class="py-1.5 pr-4">Said</th>
            <th class="py-1.5">Because</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-zinc-100 dark:divide-zinc-800">
          <tr
            :for={result <- @decision.rule_results}
            data-changed={result["rule"] in @changed}
            class={result["rule"] in @changed && "bg-amber-50/70 dark:bg-amber-500/5"}
          >
            <td class="py-1.5 pr-4 font-medium">
              {Format.label(result["rule"])}
              <.tag :if={result["rule"] in @changed} tone="amber" class="ml-1">changed</.tag>
            </td>
            <td class="py-1.5 pr-4">
              <.tag tone={outcome_tone(result["outcome"])}>{result["outcome"]}</.tag>
            </td>
            <td class="py-1.5 text-zinc-600 dark:text-zinc-400">
              {if result["reason_codes"] in [[], nil],
                do: "—",
                else: Enum.map_join(result["reason_codes"], ", ", &Format.label/1)}
            </td>
          </tr>
        </tbody>
      </table>
      <dl class="grid gap-3 text-sm sm:grid-cols-3 lg:grid-cols-5">
        <.kv label="Amount">{Format.amount(@decision.inputs["amount_minor"], @currency)}</.kv>
        <.kv label="Declared income">
          {Format.amount(@decision.inputs["declared_income_minor"], @currency)}
        </.kv>
        <.kv label="Observed income">
          {Format.amount(@decision.inputs["observed_income_minor"], @currency)}
        </.kv>
        <.kv label="Total debt">{Format.amount(@decision.inputs["total_debt_minor"], @currency)}</.kv>
        <.kv label="Score">{@decision.inputs["score"]}</.kv>
        <.kv label="Months with income">{@decision.inputs["income_months"]}</.kv>
        <.kv label="Document">
          {if @decision.inputs["document_valid?"], do: "valid", else: "invalid"}
        </.kv>
        <.kv label="Adult">{adult(@decision.inputs["adult?"])}</.kv>
        <.kv label="Previous rejection">{@decision.inputs["previous_rejection_on"] || "none"}</.kv>
        <.kv label="Evaluated on">{@decision.inputs["evaluated_on"]}</.kv>
      </dl>
      <p class="font-mono text-[11px] text-zinc-500 dark:text-zinc-400">
        decision {Format.digest(@decision.hash)} · inputs {Format.digest(@decision.inputs_hash)} · engine {String.slice(
          @decision.engine_sha,
          0,
          12
        )}
      </p>
    </article>
    """
  end

  attr :facts, :list, required: true
  attr :runs, :list, required: true

  defp agents(assigns) do
    ~H"""
    <.panel id="agents">
      <.panel_header
        title="Agents"
        subtitle="What they found about the case, and every time one of them ran."
      />
      <h3 class="px-5 pt-4 text-xs font-medium uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
        Facts
      </h3>
      <p :if={@facts == []} class="px-5 py-3 text-sm text-zinc-500 dark:text-zinc-400">
        Nothing found yet.
      </p>
      <ul id="case-facts" class="divide-y divide-zinc-100 px-5 dark:divide-zinc-800">
        <li
          :for={fact <- @facts}
          id={"fact-#{fact.id}"}
          class="flex flex-wrap items-baseline gap-x-3 gap-y-1 py-2.5 text-sm"
        >
          <span class="font-mono text-xs font-medium">{fact.name}</span>
          <code class="truncate font-mono text-xs text-zinc-600 dark:text-zinc-400">{Jason.encode!(
            fact.value
          )}</code>
          <span class="ml-auto text-xs text-zinc-500 dark:text-zinc-400">
            {fact.agent} · {fact.tool} · v{fact.lock_version} · {Format.instant(fact.inserted_at)}
          </span>
        </li>
      </ul>
      <h3 class="border-t border-zinc-200 px-5 pt-4 text-xs font-medium uppercase tracking-wider text-zinc-500 dark:border-zinc-800 dark:text-zinc-400">
        Runs
      </h3>
      <p :if={@runs == []} class="px-5 py-3 text-sm text-zinc-500 dark:text-zinc-400">
        No agent has run yet.
      </p>
      <ul id="agent-runs" class="divide-y divide-zinc-100 px-5 dark:divide-zinc-800">
        <li
          :for={run <- @runs}
          id={"run-#{run.id}"}
          class="flex flex-wrap items-center gap-x-3 gap-y-1 py-2.5 text-sm"
        >
          <span class="font-medium">{run.agent}</span>
          <.tag tone={run_tone(run.outcome)}>{run.outcome}</.tag>
          <span :if={run.proposed_state} class="text-zinc-600 dark:text-zinc-400">
            → {Format.label(run.proposed_state)}
          </span>
          <span :if={run.reason} class="text-xs text-rose-600 dark:text-rose-400">{run.reason}</span>
          <span class="ml-auto text-xs text-zinc-500 dark:text-zinc-400">
            attempt {run.attempt} · v{run.lock_version} · {Format.duration(run.duration_ms)} · {Format.instant(
              run.inserted_at
            )}
          </span>
        </li>
      </ul>
    </.panel>
    """
  end

  attr :application, :map, required: true
  attr :moves, :list, required: true
  attr :move, :atom, default: nil
  attr :form, :any, default: nil
  attr :conflict?, :boolean, default: false

  defp moves(assigns) do
    ~H"""
    <.panel id="moves">
      <.panel_header title="Actions" subtitle="What you may do with this application right now." />
      <div class="space-y-4 px-5 py-4">
        <p :if={@moves == []} class="text-sm text-zinc-500 dark:text-zinc-400">
          {why_none(@application)}
        </p>
        <div :if={@moves != []} class="flex flex-wrap gap-2">
          <.action
            :for={to <- @moves}
            id={"move-#{to}"}
            variant={move_variant(to)}
            phx-click="choose"
            phx-value-to={to}
            class={@move == to && "ring-2 ring-orange-500/40 ring-offset-2 dark:ring-offset-zinc-900"}
          >
            {move_label(to)}
          </.action>
        </div>
        <.form
          :if={@move}
          for={@form}
          id="move-form"
          phx-change="draft"
          phx-submit="move"
          class="space-y-3 rounded-xl border border-zinc-200 bg-zinc-50/60 p-4 dark:border-zinc-700 dark:bg-zinc-800/40"
        >
          <p class="text-sm">
            Moving to <strong>{Format.label(@move)}</strong>.
            <span class="text-zinc-500 dark:text-zinc-400">The reason stays in the evidence.</span>
          </p>
          <div
            :if={@conflict?}
            id="move-conflict"
            class="rounded-lg bg-amber-50 p-3 text-sm text-amber-800 dark:bg-amber-500/10 dark:text-amber-200"
          >
            The move did not happen: the application changed while you were writing. It is now <strong>{Format.label(@application.state)}</strong>, version {@application.lock_version}.
            Read it again and confirm if it still applies; what you wrote stays.
            <div class="mt-2">
              <.action id="reload-application" phx-click="reload">
                <.icon name="hero-arrow-path-mini" class="size-4" /> Read it again
              </.action>
            </div>
          </div>
          <p
            :for={error <- @form[:to].errors}
            id="move-error"
            class="flex items-center gap-1 text-sm text-rose-600 dark:text-rose-400"
          >
            <.icon name="hero-exclamation-circle-mini" class="size-4" />
            This move {translate_error(error)}
          </p>
          <.field
            field={@form[:reason]}
            type="textarea"
            label="Reason"
            rows="3"
            placeholder="Why, for whoever reads the evidence later"
          />
          <div class="flex flex-wrap gap-2">
            <.action
              type="submit"
              variant={move_variant(@move)}
              disabled={@move not in @moves}
              phx-disable-with="Moving…"
            >
              Confirm: {move_label(@move)}
            </.action>
            <.action type="button" phx-click="choose">Back</.action>
          </div>
        </.form>
      </div>
    </.panel>
    """
  end

  attr :entries, :list, required: true
  attr :currency, :string, required: true

  defp timeline(assigns) do
    ~H"""
    <.panel id="timeline">
      <.panel_header
        title="Timeline"
        subtitle="Every audited write to this application and its evidence, newest first."
      />
      <p :if={@entries == []} class="px-5 py-4 text-sm text-zinc-500 dark:text-zinc-400">
        Nothing recorded yet.
      </p>
      <ol class="px-5 py-4">
        <li
          :for={entry <- @entries}
          id={"entry-#{entry.id}"}
          class="relative pb-5 pl-6 last:pb-0 before:absolute before:left-[5px] before:top-2 before:h-full before:w-px before:bg-zinc-200 last:before:hidden dark:before:bg-zinc-800"
        >
          <span class="absolute left-0 top-1.5 size-[11px] rounded-full border-2 border-orange-500 bg-white dark:bg-zinc-900" />
          <div class="flex flex-wrap items-baseline gap-x-2 text-xs text-zinc-500 dark:text-zinc-400">
            <time class="tabular-nums">{Format.instant(entry.at)}</time>
            <span class="font-medium text-zinc-700 dark:text-zinc-300">{Format.actor(entry.actor)}</span>
          </div>
          <p :if={entry.reason} class="mt-0.5 text-sm italic text-zinc-600 dark:text-zinc-400">
            {entry.reason}
          </p>
          <ul class="mt-1 space-y-0.5 text-sm">
            <li :for={change <- entry.changes}>{change_text(change, @currency)}</li>
          </ul>
        </li>
      </ol>
    </.panel>
    """
  end

  defp policy(policies, id), do: Map.get(policies, id)

  defp who(user_id, user_id), do: "you"
  defp who(staff_id, _user_id), do: Format.actor("staff_user:" <> staff_id)

  defp move_label(:approved), do: "Approve"
  defp move_label(:pending_countersign), do: "Approve, for countersign"
  defp move_label(:rejected), do: "Reject"
  defp move_label(:info_requested), do: "Request information"
  defp move_label(:in_review), do: "Return to review"
  defp move_label(:cancelled), do: "Cancel the application"
  defp move_label(other), do: "Move to " <> Format.label(other)

  defp move_variant(to) when to in [:approved, :pending_countersign], do: "primary"
  defp move_variant(to) when to in [:rejected, :cancelled], do: "danger"
  defp move_variant(_other), do: "quiet"

  defp why_none(%{state: state}) when state in [:approved, :rejected, :cancelled],
    do: "The application is #{Format.label(state)}, which is final: nothing moves it."

  defp why_none(%{state: state}) do
    "Nothing for you to do from here right now: #{Format.label(state)} is in the system's " <>
      "hands, or waits on someone else."
  end

  defp adult(nil), do: "not encoded in the document"
  defp adult(true), do: "yes"
  defp adult(false), do: "no"

  defp outcome_tone(outcome) when outcome in [:approve, "approve"], do: "emerald"
  defp outcome_tone(outcome) when outcome in [:review, "review"], do: "amber"
  defp outcome_tone(outcome) when outcome in [:reject, "reject"], do: "rose"
  defp outcome_tone(_other), do: "zinc"

  defp run_tone(:advance), do: "emerald"
  defp run_tone(:superseded), do: "zinc"
  defp run_tone(:retry), do: "amber"
  defp run_tone(:escalate), do: "rose"

  defp exchange_tone(:ok), do: "emerald"
  defp exchange_tone(:pending), do: "sky"
  defp exchange_tone(:timeout), do: "amber"
  defp exchange_tone(:error), do: "rose"

  # One line for each row the evidence says was written
  defp change_text(%{table: "credit_applications", op: :insert, data: data}, _currency),
    do: "Application created in #{Format.label(data["state"])}"

  defp change_text(%{table: "credit_applications", op: :update} = change, _currency) do
    %{changed: changed, data: data, before: before} = change

    cond do
      "state" in changed and is_binary(before["state"]) ->
        "State: #{Format.label(before["state"])} → #{Format.label(data["state"])}"

      "state" in changed ->
        "Moved to #{Format.label(data["state"])}"

      "revision" in changed ->
        "Revision #{data["revision"]} is now current"

      "policy_version_id" in changed ->
        "Policy version recorded"

      true ->
        "Application updated"
    end
  end

  defp change_text(%{table: "application_revisions", data: data}, currency) do
    "Revision #{data["number"]}: #{Format.amount(data["amount_minor"], currency)} requested, " <>
      "#{Format.amount(data["monthly_income_minor"], currency)} a month (#{Format.label(data["cause"])})"
  end

  defp change_text(%{table: "bank_profiles", data: data}, currency) do
    "Bank profile: score #{data["score"]}, " <>
      "#{Format.amount(data["observed_income_minor"], currency)} a month observed (#{data["origin"]})"
  end

  defp change_text(%{table: "decision_records", data: data}, _currency) do
    codes = Enum.map_join(data["reason_codes"] || [], ", ", &Format.label/1)
    "Decision: #{Format.label(data["outcome"])}" <> if(codes == "", do: "", else: " (#{codes})")
  end

  defp change_text(%{table: "case_facts", data: data}, _currency),
    do: "Fact #{data["name"]}, by #{data["agent"]} with #{data["tool"]}"

  defp change_text(%{table: "notifications", op: :insert, data: data}, _currency),
    do:
      "Notice #{Format.label(data["template"])} by #{data["channel"]}: #{Format.label(data["state"])}"

  defp change_text(%{table: "notifications", data: data}, _currency),
    do: "Notice #{Format.label(data["template"])} #{Format.label(data["state"])}"

  defp change_text(%{table: table, op: op}, _currency), do: "#{op} on #{table}"
end
