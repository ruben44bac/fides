defmodule FidesWeb.PoliciesLive do
  @moduledoc """
  A country's risk policy as versions of its thresholds: the one in force, every
  version with who proposed and published it and how many decisions it made, and the
  differences between them. A risk manager of the country proposes a version as a
  draft, and another risk manager puts it in force, which sends the applications
  waiting for review under an older version back to evaluation. Everyone else reads.
  """

  use FidesWeb, :live_view

  alias FidesWeb.Format
  alias FidesWeb.PolicyForm
  alias FidesWeb.StaffScope

  @impl true
  def mount(_params, _session, socket) do
    currencies = Map.new(Fides.Countries.list_countries!(), &{&1.code, &1.currency})

    {:ok, assign(socket, page_title: "Policies", currencies: currencies, expanded: MapSet.new())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    %{current_scope: scope} = socket.assigns

    country =
      if params["country"] in scope.countries,
        do: params["country"],
        else: List.first(scope.countries)

    {:noreply, socket |> assign(:country, country) |> load() |> assign_form(nil, [])}
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("draft", %{"policy" => params}, socket),
    do: {:noreply, assign_form(socket, params, [])}

  def handle_event("propose", %{"policy" => params}, socket) do
    %{country: country, names: names, current_scope: scope} = socket.assigns

    with {:ok, thresholds} <- PolicyForm.cast(params, names),
         {:ok, version} <-
           Fides.Risk.propose_policy(thresholds, tenant: country, actor: scope.user) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "Version #{version.version} proposed. Another risk manager publishes it."
       )
       |> load()
       |> assign_form(nil, [])}
    else
      {:error, errors} when is_list(errors) ->
        {:noreply, assign_form(socket, params, errors)}

      {:error, error} ->
        {:noreply, assign_form(socket, params, refused(error))}
    end
  end

  def handle_event("publish", %{"id" => id}, socket) do
    %{country: country, versions: versions, current_scope: scope} = socket.assigns

    with %{} = version <- Enum.find(versions, &(&1.id == id)),
         {:ok, published} <-
           Fides.Risk.publish_policy(version, tenant: country, actor: scope.user) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "Version #{published.version} is in force. Applications waiting for review under an older version go back to evaluation."
       )
       |> load()}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "That version is no longer here.")}

      {:error, error} ->
        {:noreply, socket |> put_flash(:error, "Not published: " <> reason(error)) |> load()}
    end
  end

  defp load(socket) do
    %{country: country, current_scope: scope} = socket.assigns
    {:ok, names} = Fides.Risk.param_names(country)
    common = Fides.Risk.common_param_names()
    versions = read!(Fides.Risk.policy_versions(country, scope.user))
    in_force = Enum.find(versions, &(&1.status == :published))

    assign(socket,
      names: names,
      common: common,
      own: names -- common,
      versions: versions,
      in_force: in_force,
      in_force_params: in_force && thresholds!(country, in_force.params),
      currency: Map.fetch!(socket.assigns.currencies, country),
      may_propose?: StaffScope.role(scope, country) == :risk_manager
    )
  end

  # The form starts from the version in force, or the country's first thresholds
  defp assign_form(socket, nil, errors) do
    %{country: country, names: names, in_force_params: in_force} = socket.assigns
    {:ok, defaults} = Fides.Risk.default_params(country)
    assign_form(socket, PolicyForm.values(in_force || defaults, names), errors)
  end

  defp assign_form(socket, params, errors) do
    %{names: names, in_force_params: in_force} = socket.assigns

    proposed =
      case PolicyForm.cast(params, names) do
        {:ok, thresholds} -> PolicyForm.diff(in_force, thresholds, names)
        {:error, _errors} -> []
      end

    assign(socket,
      form: to_form(params, as: :policy, errors: errors),
      changes: Enum.filter(proposed, & &1.changed?),
      general_errors: for({:params, error} <- errors, do: translate_error(error))
    )
  end

  defp thresholds!(country, params) do
    {:ok, thresholds} = Fides.Risk.cast_params(country, params)
    thresholds
  end

  defp read!({:ok, items}), do: items
  defp read!({:error, error}) when is_exception(error), do: raise(error)

  # The action's refusal names the parameters as a whole, or a threshold
  defp refused(%{errors: errors}) when is_list(errors) do
    Enum.map(errors, fn
      %{field: field, message: message} = error when is_atom(field) and is_binary(message) ->
        {field, {message, Map.get(error, :vars) || []}}

      error ->
        {:params, {reason(error), []}}
    end)
  end

  defp refused(error), do: [params: {reason(error), []}]

  defp reason(%{errors: [error | _rest]}), do: reason(error)
  defp reason(%{message: message}) when is_binary(message), do: message
  defp reason(error) when is_exception(error), do: Exception.message(error)
  defp reason(error), do: inspect(error)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={:policies}>
      <div class={["space-y-6", not @may_propose? && "mx-auto max-w-5xl"]}>
        <.page_header
          title="Policies"
          subtitle="Each country decides with the thresholds of its version in force. The rules are code; the thresholds are these."
        >
          <:actions>
            <nav
              id="countries"
              class="flex rounded-xl border border-zinc-200 bg-white p-1 shadow-sm dark:border-zinc-800 dark:bg-zinc-900"
              aria-label="Country"
            >
              <.link
                :for={country <- @current_scope.countries}
                id={"country-#{country}"}
                patch={~p"/backoffice/policies?#{%{country: country}}"}
                aria-current={country == @country && "page"}
                class={[
                  "rounded-lg px-3 py-1.5 text-sm font-medium transition-colors",
                  country == @country && "bg-orange-600 text-white shadow-sm",
                  country != @country &&
                    "text-zinc-600 hover:bg-zinc-100 dark:text-zinc-400 dark:hover:bg-zinc-800"
                ]}
              >
                {country}
              </.link>
            </nav>
          </:actions>
        </.page_header>

        <div class={["grid gap-6", @may_propose? && "xl:grid-cols-3"]}>
          <div class={["space-y-6", @may_propose? && "xl:col-span-2"]}>
            <.in_force
              version={@in_force}
              params={@in_force_params}
              common={@common}
              own={@own}
              country={@country}
              currency={@currency}
              user_id={@current_scope.user.id}
            />
            <.versions
              versions={@versions}
              in_force={@in_force_params}
              names={@names}
              currency={@currency}
              expanded={@expanded}
              may_propose?={@may_propose?}
              user_id={@current_scope.user.id}
            />
          </div>
          <div :if={@may_propose?} class="space-y-6">
            <.propose
              form={@form}
              common={@common}
              own={@own}
              changes={@changes}
              currency={@currency}
              country={@country}
              in_force={@in_force}
              general_errors={@general_errors}
            />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :version, :map, default: nil
  attr :params, :map, default: nil
  attr :common, :list, required: true
  attr :own, :list, required: true
  attr :country, :string, required: true
  attr :currency, :string, required: true
  attr :user_id, :string, required: true

  defp in_force(assigns) do
    ~H"""
    <.panel id="in-force">
      <.panel_header
        title="In force"
        subtitle={
          if @version,
            do:
              "Version #{@version.version} has decided #{Format.country(@country)}'s applications since #{Format.moment(@version.effective_from)}, published by #{Format.staff(@version.approved_by, @user_id)}.",
            else:
              "No version is in force in #{Format.country(@country)}: Risk escalates every evaluation to a person until one is published."
        }
      >
        <:actions>
          <.tag :if={@version} tone="emerald" class="text-sm">v{@version.version} · in force</.tag>
        </:actions>
      </.panel_header>
      <div :if={@params} class="space-y-5 px-5 py-4">
        <section>
          <h3 class="mb-2 text-xs font-medium uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
            Rules every country applies
          </h3>
          <div class="grid gap-3 sm:grid-cols-2">
            <.stat
              :for={name <- @common}
              id={"in-force-#{name}"}
              label={PolicyForm.label(name)}
              hint={PolicyForm.describe(name)}
            >
              {PolicyForm.format(name, @params[name], @currency)}
            </.stat>
          </div>
        </section>
        <section>
          <h3 class="mb-2 text-xs font-medium uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
            {Format.country(@country)}'s own rule
          </h3>
          <div class="grid gap-3 sm:grid-cols-2">
            <.stat
              :for={name <- @own}
              id={"in-force-#{name}"}
              label={PolicyForm.label(name)}
              hint={PolicyForm.describe(name)}
            >
              {PolicyForm.format(name, @params[name], @currency)}
            </.stat>
          </div>
        </section>
      </div>
    </.panel>
    """
  end

  attr :versions, :list, required: true
  attr :in_force, :map, default: nil
  attr :names, :list, required: true
  attr :currency, :string, required: true
  attr :expanded, :any, required: true
  attr :may_propose?, :boolean, required: true
  attr :user_id, :string, required: true

  defp versions(assigns) do
    ~H"""
    <.panel id="versions">
      <.panel_header
        title="Versions"
        subtitle="Newest first. A draft becomes the version in force when a risk manager other than its proposer publishes it, and the one before retires."
      />
      <p :if={@versions == []} class="px-5 py-4 text-sm text-zinc-500 dark:text-zinc-400">
        No version yet.
      </p>
      <ul class="divide-y divide-zinc-200 dark:divide-zinc-800">
        <li :for={version <- @versions} id={"version-#{version.id}"} class="px-5 py-4">
          <div class="flex flex-wrap items-start gap-4">
            <span class={[
              "flex size-11 shrink-0 items-center justify-center rounded-xl text-sm font-bold tabular-nums",
              version.status == :published &&
                "bg-emerald-600 text-white shadow-sm shadow-emerald-600/30",
              version.status == :draft &&
                "bg-amber-100 text-amber-800 dark:bg-amber-500/15 dark:text-amber-300",
              version.status == :retired &&
                "bg-zinc-100 text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400"
            ]}>
              v{version.version}
            </span>
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-2">
                <.tag tone={status_tone(version.status)}>{version.status}</.tag>
                <span class="text-sm text-zinc-600 dark:text-zinc-400">
                  proposed by {Format.staff(version.proposed_by, @user_id)}
                  <span title={Format.instant(version.inserted_at)}>
                    {Format.relative(version.inserted_at)}
                  </span>
                </span>
                <span :if={version.approved_by} class="text-sm text-zinc-600 dark:text-zinc-400">
                  · published by {Format.staff(version.approved_by, @user_id)}
                  <span :if={version.effective_from} title={Format.instant(version.effective_from)}>
                    {Format.relative(version.effective_from)}
                  </span>
                </span>
              </div>
              <p class="mt-1 text-sm tabular-nums text-zinc-600 dark:text-zinc-400">
                {version.decisions_count} decisions<span :if={version.reevaluations_count > 0}>, {version.reevaluations_count} by reevaluation</span>
              </p>
              <p
                :if={version.status == :draft and version.proposed_by == @user_id}
                id={"own-draft-#{version.id}"}
                class="mt-1 text-sm text-amber-700 dark:text-amber-300"
              >
                Proposed by you: another risk manager publishes it.
              </p>
            </div>
            <div class="flex shrink-0 flex-wrap items-center gap-2">
              <.action
                :if={version.status == :draft and @may_propose? and version.proposed_by != @user_id}
                id={"publish-#{version.id}"}
                variant="primary"
                phx-click="publish"
                phx-value-id={version.id}
                phx-disable-with="Publishing…"
              >
                <.icon name="hero-check-badge-mini" class="size-4" /> Publish v{version.version}
              </.action>
              <.action id={"toggle-#{version.id}"} phx-click="toggle" phx-value-id={version.id}>
                <.icon
                  name={
                    if MapSet.member?(@expanded, version.id),
                      do: "hero-chevron-up-mini",
                      else: "hero-chevron-down-mini"
                  }
                  class="size-4"
                /> Thresholds
              </.action>
            </div>
          </div>
          <.thresholds
            :if={MapSet.member?(@expanded, version.id)}
            id={"thresholds-#{version.id}"}
            rows={PolicyForm.diff(@in_force, version_thresholds(version), @names)}
            against={@in_force != nil and version.status != :published}
            currency={@currency}
          />
        </li>
      </ul>
    </.panel>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :against, :boolean, default: false
  attr :currency, :string, required: true

  # A version's thresholds; against the version in force, the ones that differ stand out
  defp thresholds(assigns) do
    ~H"""
    <table id={@id} class="mt-4 w-full text-sm">
      <thead class="text-left text-[11px] font-medium uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
        <tr>
          <th class="py-1.5 pr-4">Threshold</th>
          <th :if={@against} class="py-1.5 pr-4 text-right">In force</th>
          <th class="py-1.5 text-right">{if @against, do: "This version", else: "Value"}</th>
        </tr>
      </thead>
      <tbody class="divide-y divide-zinc-100 dark:divide-zinc-800">
        <tr
          :for={row <- @rows}
          data-changed={@against and row.changed?}
          class={(@against and row.changed?) && "bg-amber-50/70 dark:bg-amber-500/5"}
        >
          <td class="py-1.5 pr-4 font-medium">
            {PolicyForm.label(row.name)}
            <.tag :if={@against and row.changed?} tone="amber" class="ml-1">changes</.tag>
          </td>
          <td
            :if={@against}
            class="py-1.5 pr-4 text-right tabular-nums text-zinc-500 dark:text-zinc-400"
          >
            {if row.before, do: PolicyForm.format(row.name, row.before, @currency), else: "—"}
          </td>
          <td class="py-1.5 text-right font-medium tabular-nums">
            {PolicyForm.format(row.name, row.after, @currency)}
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  attr :form, :any, required: true
  attr :common, :list, required: true
  attr :own, :list, required: true
  attr :changes, :list, required: true
  attr :currency, :string, required: true
  attr :country, :string, required: true
  attr :in_force, :map, default: nil
  attr :general_errors, :list, required: true

  defp propose(assigns) do
    ~H"""
    <.panel id="propose">
      <.panel_header
        title="Propose a version"
        subtitle={"#{Format.country(@country)}'s thresholds, starting from #{if @in_force, do: "the version in force", else: "the first ones"}. Another risk manager publishes it."}
      />
      <.form
        for={@form}
        id="propose-form"
        phx-change="draft"
        phx-submit="propose"
        class="space-y-5 px-5 py-4"
      >
        <p
          :for={error <- @general_errors}
          class="flex items-start gap-1 rounded-lg bg-rose-50 px-3 py-2 text-sm text-rose-700 dark:bg-rose-500/10 dark:text-rose-300"
        >
          <.icon name="hero-exclamation-circle-mini" class="mt-0.5 size-4 shrink-0" /> {error}
        </p>
        <section class="space-y-4">
          <h3 class="text-xs font-medium uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
            Rules every country applies
          </h3>
          <.field
            :for={name <- @common}
            field={@form[name]}
            label={PolicyForm.label(name)}
            hint={PolicyForm.describe(name)}
            suffix={PolicyForm.suffix(name, @currency)}
            inputmode="decimal"
          />
        </section>
        <section class="space-y-4">
          <h3 class="text-xs font-medium uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
            {Format.country(@country)}'s own rule
          </h3>
          <.field
            :for={name <- @own}
            field={@form[name]}
            label={PolicyForm.label(name)}
            hint={PolicyForm.describe(name)}
            suffix={PolicyForm.suffix(name, @currency)}
            inputmode="decimal"
          />
        </section>
        <div
          id="what-changes"
          class="rounded-xl border border-dashed border-zinc-300 px-4 py-3 text-sm dark:border-zinc-700"
        >
          <p :if={@changes == []} class="text-zinc-500 dark:text-zinc-400">
            Nothing differs from the version in force yet.
          </p>
          <ul :if={@changes != []} class="space-y-1">
            <li :for={row <- @changes} class="flex flex-wrap items-baseline gap-x-2">
              <span class="font-medium">{PolicyForm.label(row.name)}</span>
              <span :if={row.before} class="text-zinc-500 line-through dark:text-zinc-400">
                {PolicyForm.format(row.name, row.before, @currency)}
              </span>
              <span class="tabular-nums text-amber-700 dark:text-amber-300">
                {PolicyForm.format(row.name, row.after, @currency)}
              </span>
            </li>
          </ul>
        </div>
        <.action
          type="submit"
          variant="primary"
          disabled={@changes == []}
          phx-disable-with="Proposing…"
          class="w-full"
        >
          <.icon name="hero-document-plus-mini" class="size-4" /> Propose as a draft
        </.action>
      </.form>
    </.panel>
    """
  end

  defp version_thresholds(version), do: thresholds!(version.country_code, version.params)

  defp status_tone(:published), do: "emerald"
  defp status_tone(:draft), do: "amber"
  defp status_tone(:retired), do: "zinc"
end
