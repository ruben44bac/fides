defmodule FidesWeb.SettingsLive do
  @moduledoc """
  The staff user's own corner: who they are and where they work, the theme the pages
  follow, and the way out.
  """

  use FidesWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Settings")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={:settings}>
      <div class="mx-auto max-w-3xl space-y-6">
        <.page_header title="Settings" subtitle="Your account, how the pages look, and the way out." />

        <.panel class="p-6">
          <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
            Account
          </h2>
          <dl class="mt-4 grid gap-4 sm:grid-cols-2">
            <div>
              <dt class="text-xs text-zinc-500 dark:text-zinc-400">Email</dt>
              <dd id="account-email" class="mt-1 text-sm font-medium">{@current_scope.user.email}</dd>
            </div>
            <div>
              <dt class="text-xs text-zinc-500 dark:text-zinc-400">
                {if @current_scope.global_role, do: "Role", else: "Countries"}
              </dt>
              <dd id="account-scope" class="mt-1 flex flex-wrap gap-1.5">
                <span
                  :for={label <- scope_labels(@current_scope)}
                  class="rounded-md bg-zinc-100 px-2 py-0.5 text-xs font-medium text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"
                >
                  {label}
                </span>
              </dd>
            </div>
          </dl>
        </.panel>

        <.panel class="p-6">
          <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
            Appearance
          </h2>
          <p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
            The theme is remembered in this browser.
          </p>
          <div class="mt-4">
            <.theme_switch labels />
          </div>
        </.panel>

        <.panel class="flex flex-wrap items-center justify-between gap-4 p-6">
          <div>
            <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
              Session
            </h2>
            <p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
              Signing out revokes this session's token everywhere it was used.
            </p>
          </div>
          <.action id="sign-out" href={~p"/backoffice/sign-out"} method="delete">
            <.icon name="hero-arrow-right-start-on-rectangle-mini" class="size-4" /> Sign out
          </.action>
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  defp scope_labels(%{global_role: role}) when not is_nil(role), do: [Atom.to_string(role)]
  defp scope_labels(%{countries: countries}), do: countries
end
