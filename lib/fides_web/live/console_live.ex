defmodule FidesWeb.ConsoleLive do
  @moduledoc """
  What the operation looks like right now, for the countries the staff user works in:
  how deep each queue is, how each country's bank provider has been answering and
  which applications wait in provider error, and the webhook deliveries that failed
  every attempt, to send again. The screen reads everything again every few seconds.
  """

  use FidesWeb, :live_view

  alias FidesWeb.Format
  alias FidesWeb.StaffScope

  @refresh_every 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_every)

    {:ok, socket |> assign(page_title: "Console") |> load()}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  def handle_event("resend", %{"id" => id, "country" => country}, socket) do
    %{deliveries: deliveries, current_scope: scope} = socket.assigns

    with %{} = delivery <- Enum.find(deliveries, &(&1.id == id and &1.country_code == country)),
         {:ok, _pending} <- Fides.Notifications.resend_delivery(delivery, scope.user) do
      {:noreply,
       socket
       |> put_flash(:info, "The delivery goes out again; its attempts start over.")
       |> load()}
    else
      nil ->
        {:noreply, socket |> put_flash(:error, "That delivery is no longer failed.") |> load()}

      {:error, %Ash.Error.Forbidden{}} ->
        {:noreply, put_flash(socket, :error, "You may not resend deliveries in #{country}.")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Not resent: " <> reason(error))}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_every)
    {:noreply, load(socket)}
  end

  defp load(socket) do
    %{current_scope: scope} = socket.assigns
    actor = scope.user

    assign(socket,
      queues: Fides.Orchestration.queue_depths(),
      providers:
        Enum.map(scope.countries, &{&1, read!(Fides.Banking.provider_status(&1, actor))}),
      stuck:
        read!(Fides.Origination.inbox(%{state: :provider_error, limit: 100}, actor: actor)).results,
      deliveries:
        Enum.flat_map(scope.countries, &read!(Fides.Notifications.failed_deliveries(&1, actor))),
      endpoints: endpoint_names(actor),
      resends: Enum.filter(scope.countries, &(StaffScope.role(scope, &1) in [:admin, :analyst])),
      refreshed_at: DateTime.utc_now()
    )
  end

  # Receivers are the admin's: for everyone else a delivery names its receiver by id
  defp endpoint_names(actor) do
    case Fides.Notifications.list_endpoints(actor: actor) do
      {:ok, endpoints} -> Map.new(endpoints, &{&1.id, &1.name})
      {:error, _forbidden} -> %{}
    end
  end

  defp refresh_seconds, do: div(@refresh_every, 1000)

  defp read!({:ok, result}), do: result
  defp read!({:error, error}) when is_exception(error), do: raise(error)

  defp reason(%{errors: [error | _rest]}), do: reason(error)
  defp reason(%{message: message}) when is_binary(message), do: message
  defp reason(error) when is_exception(error), do: Exception.message(error)
  defp reason(error), do: inspect(error)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={:console}>
      <div class="space-y-6">
        <.page_header
          title="Console"
          subtitle={"The operation in #{Enum.join(@current_scope.countries, ", ")}, read again every #{refresh_seconds()} seconds."}
        >
          <:actions>
            <span class="text-xs text-zinc-500 dark:text-zinc-400" id="refreshed-at">
              as of {Format.instant(@refreshed_at)}
            </span>
            <.action id="refresh" phx-click="refresh">
              <.icon name="hero-arrow-path-mini" class="size-4" /> Refresh
            </.action>
          </:actions>
        </.page_header>

        <div class="grid gap-6 xl:grid-cols-2">
          <.queues queues={@queues} />
          <.providers providers={@providers} stuck={@stuck} />
        </div>

        <.deliveries deliveries={@deliveries} endpoints={@endpoints} resends={@resends} />
      </div>
    </Layouts.app>
    """
  end

  attr :queues, :list, required: true

  defp queues(assigns) do
    ~H"""
    <.panel id="queues">
      <.panel_header
        title="Queues"
        subtitle="One per agent and one per bank provider, so a slow provider holds nobody else up."
      />
      <table class="w-full text-sm">
        <thead class="text-left text-[11px] font-medium uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
          <tr>
            <th class="px-5 py-2.5">Queue</th>
            <th class="px-5 py-2.5 text-right">Waiting</th>
            <th class="px-5 py-2.5 text-right">Scheduled</th>
            <th class="px-5 py-2.5 text-right">Running</th>
            <th class="px-5 py-2.5 text-right">Retrying</th>
            <th class="px-5 py-2.5 text-right">Given up</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-zinc-100 dark:divide-zinc-800">
          <tr :for={%{queue: queue, counts: counts} <- @queues} id={"queue-#{queue}"}>
            <td class="px-5 py-2 font-mono text-xs">{queue}</td>
            <td class="px-5 py-2 text-right tabular-nums"><.depth n={counts["available"]} /></td>
            <td class="px-5 py-2 text-right tabular-nums"><.depth n={counts["scheduled"]} /></td>
            <td class="px-5 py-2 text-right tabular-nums"><.depth n={counts["executing"]} /></td>
            <td class="px-5 py-2 text-right tabular-nums">
              <.depth n={counts["retryable"]} tone="amber" />
            </td>
            <td class="px-5 py-2 text-right tabular-nums">
              <.depth n={counts["discarded"]} tone="rose" />
            </td>
          </tr>
        </tbody>
      </table>
    </.panel>
    """
  end

  attr :n, :integer, required: true
  attr :tone, :string, default: "zinc"

  # A zero fades out; anything else stands in its tone
  defp depth(%{n: 0} = assigns) do
    ~H"""
    <span class="text-zinc-300 dark:text-zinc-600">0</span>
    """
  end

  defp depth(assigns) do
    ~H"""
    <.tag tone={@tone}>{@n}</.tag>
    """
  end

  attr :providers, :list, required: true
  attr :stuck, :list, required: true

  defp providers(assigns) do
    ~H"""
    <.panel id="providers">
      <.panel_header
        title="Bank providers"
        subtitle="Each country's provider, by its calls of the last 24 hours, and the applications waiting in provider error."
      />
      <ul class="divide-y divide-zinc-100 dark:divide-zinc-800">
        <li :for={{country, status} <- @providers} id={"provider-#{country}"} class="px-5 py-3">
          <div class="flex flex-wrap items-center gap-2 text-sm">
            <.tag>{country}</.tag>
            <%= if status do %>
              <span class="font-medium">{status.provider.name}</span>
              <span class="text-xs text-zinc-500 dark:text-zinc-400">{status.provider.mode}</span>
              <.tag tone={health_tone(status)} class="ml-auto">{health(status)}</.tag>
            <% else %>
              <span class="text-zinc-500 dark:text-zinc-400">no active provider</span>
            <% end %>
          </div>
          <p :if={status} class="mt-1 text-xs text-zinc-500 dark:text-zinc-400">
            {status.calls} calls in 24 h, {status.failures} failed<span :if={status.last}>; last one {Format.label(
              status.last.status
            )} <span title={Format.instant(status.last.inserted_at)}>{Format.relative(status.last.inserted_at)}</span>, {Format.duration(
              status.last.latency_ms
            )}</span><span :if={status.last && status.last.error}>: {status.last.error}</span>
          </p>
        </li>
      </ul>
      <div class="border-t border-zinc-200 px-5 py-3 dark:border-zinc-800">
        <h3 class="text-xs font-medium uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
          In provider error
        </h3>
        <p :if={@stuck == []} id="stuck-none" class="mt-2 text-sm text-zinc-500 dark:text-zinc-400">
          No application waits on a provider.
        </p>
        <ul :if={@stuck != []} id="stuck" class="mt-2 space-y-1 text-sm">
          <li
            :for={application <- @stuck}
            id={"stuck-#{application.id}"}
            class="flex flex-wrap items-center gap-2"
          >
            <.tag>{application.country_code}</.tag>
            <.link
              navigate={~p"/backoffice/applications/#{application.id}"}
              class="font-mono text-xs text-orange-700 hover:underline dark:text-orange-300"
            >
              {Format.short_id(application.id)}
            </.link>
            <span class="tabular-nums">{Format.amount(application.amount_minor, application.currency)}</span>
            <span
              class="text-xs text-zinc-500 dark:text-zinc-400"
              title={Format.instant(application.updated_at)}
            >
              since {Format.relative(application.updated_at)}
            </span>
          </li>
        </ul>
      </div>
    </.panel>
    """
  end

  attr :deliveries, :list, required: true
  attr :endpoints, :map, required: true
  attr :resends, :list, required: true

  defp deliveries(assigns) do
    ~H"""
    <.panel id="failed-deliveries">
      <.panel_header
        title="Failed webhook deliveries"
        subtitle="Deliveries that failed every attempt. Sending one again starts its attempts over."
      />
      <p
        :if={@deliveries == []}
        id="failed-none"
        class="px-5 py-4 text-sm text-zinc-500 dark:text-zinc-400"
      >
        Every delivery reached its receiver, or is still being tried.
      </p>
      <table :if={@deliveries != []} class="w-full text-sm">
        <thead class="text-left text-[11px] font-medium uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
          <tr>
            <th class="px-5 py-2.5">Receiver</th>
            <th class="px-5 py-2.5">Event</th>
            <th class="px-5 py-2.5">Application</th>
            <th class="px-5 py-2.5 text-right">Attempts</th>
            <th class="px-5 py-2.5 text-right">Last answer</th>
            <th class="px-5 py-2.5 text-right">Failed</th>
            <th class="px-5 py-2.5"></th>
          </tr>
        </thead>
        <tbody class="divide-y divide-zinc-100 dark:divide-zinc-800">
          <tr :for={delivery <- @deliveries} id={"delivery-#{delivery.id}"}>
            <td class="px-5 py-2.5">
              {Map.get(
                @endpoints,
                delivery.endpoint_id,
                "receiver " <> Format.short_id(delivery.endpoint_id)
              )}
            </td>
            <td class="px-5 py-2.5">
              <.tag>{delivery.country_code}</.tag>
              {Format.label(delivery.event_type)}
            </td>
            <td class="px-5 py-2.5">
              <.link
                navigate={~p"/backoffice/applications/#{delivery.application_id}"}
                class="font-mono text-xs text-orange-700 hover:underline dark:text-orange-300"
              >
                {Format.short_id(delivery.application_id)}
              </.link>
            </td>
            <td class="px-5 py-2.5 text-right tabular-nums">{delivery.attempts}</td>
            <td class="px-5 py-2.5 text-right tabular-nums">{delivery.last_status || "no answer"}</td>
            <td
              class="px-5 py-2.5 text-right text-zinc-600 dark:text-zinc-400"
              title={Format.instant(delivery.attempted_at)}
            >
              {Format.relative(delivery.attempted_at)}
            </td>
            <td class="px-5 py-2.5 text-right">
              <.action
                :if={delivery.country_code in @resends}
                id={"resend-#{delivery.id}"}
                variant="primary"
                phx-click="resend"
                phx-value-id={delivery.id}
                phx-value-country={delivery.country_code}
                phx-disable-with="Sending…"
              >
                <.icon name="hero-paper-airplane-mini" class="size-4" /> Resend
              </.action>
            </td>
          </tr>
        </tbody>
      </table>
    </.panel>
    """
  end

  defp health(%{calls: 0}), do: "quiet"
  defp health(%{failures: 0}), do: "healthy"
  defp health(%{last: %{status: status}}) when status in [:error, :timeout], do: "failing"
  defp health(_status), do: "recovering"

  defp health_tone(%{calls: 0}), do: "zinc"
  defp health_tone(%{failures: 0}), do: "emerald"
  defp health_tone(%{last: %{status: status}}) when status in [:error, :timeout], do: "rose"
  defp health_tone(_status), do: "amber"
end
