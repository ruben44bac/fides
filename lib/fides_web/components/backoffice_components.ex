defmodule FidesWeb.BackofficeComponents do
  @moduledoc """
  The backoffice's own components: the brand, page headers and panels, form fields
  and buttons, the badge of an application's state, who is signed in, and the theme
  switch. Plain Tailwind classes, in light and dark, so every screen looks the same.
  """

  use Phoenix.Component

  import FidesWeb.CoreComponents, only: [icon: 1, translate_error: 1]

  alias Phoenix.LiveView.JS

  @doc "The mark and the name."
  attr :href, :string, default: "/backoffice"
  attr :subtitle, :string, default: nil

  def brand(assigns) do
    ~H"""
    <a href={@href} class="group flex items-center gap-2.5">
      <span class="flex size-8 items-center justify-center rounded-lg bg-gradient-to-br from-orange-500 to-orange-600 text-sm font-bold text-white shadow-sm shadow-orange-500/30 transition-transform group-hover:scale-105">
        F
      </span>
      <span class="flex items-baseline gap-2 [[data-sidebar=collapsed]_&]:hidden">
        <span class="text-base font-semibold tracking-tight">Fides</span>
        <span :if={@subtitle} class="hidden text-sm text-zinc-500 sm:inline dark:text-zinc-400">
          {@subtitle}
        </span>
      </span>
    </a>
    """
  end

  @doc """
  The menu on the left: the brand, the screens, who is signed in, and a handle that
  folds it to its icons. The page remembers whether it is folded.
  """
  attr :scope, :map, required: true
  attr :nav, :atom, default: nil

  def sidebar(assigns) do
    ~H"""
    <aside
      id="sidebar"
      class="sticky top-0 flex h-screen w-60 shrink-0 flex-col border-r border-zinc-200 bg-white transition-[width] duration-200 dark:border-zinc-800 dark:bg-zinc-900 [[data-sidebar=collapsed]_&]:w-16"
    >
      <div class="flex h-14 items-center border-b border-zinc-200 px-3 dark:border-zinc-800">
        <.brand subtitle="Backoffice" />
      </div>

      <nav class="flex flex-1 flex-col gap-1 p-2">
        <.sidebar_item
          navigate="/backoffice"
          icon="hero-inbox"
          label="Inbox"
          current={@nav == :inbox}
        />
        <.sidebar_item
          navigate="/backoffice/settings"
          icon="hero-cog-6-tooth"
          label="Settings"
          current={@nav == :settings}
        />
      </nav>

      <.link
        navigate="/backoffice/settings"
        id="current-staff"
        class="flex items-center gap-3 border-t border-zinc-200 px-3 py-3 transition-colors hover:bg-zinc-50 dark:border-zinc-800 dark:hover:bg-zinc-800/60"
        title={@scope.user.email}
      >
        <span class="flex size-9 shrink-0 items-center justify-center rounded-full bg-orange-100 text-xs font-semibold uppercase text-orange-700 dark:bg-orange-500/15 dark:text-orange-300">
          {initials(@scope.user.email)}
        </span>
        <span class="min-w-0 leading-tight [[data-sidebar=collapsed]_&]:hidden">
          <span class="block truncate text-sm font-medium">{@scope.user.email}</span>
          <span class="flex gap-1 text-[11px] text-zinc-500 dark:text-zinc-400">
            <span :for={label <- scope_labels(@scope)}>{label}</span>
          </span>
        </span>
      </.link>

      <button
        type="button"
        id="sidebar-toggle"
        class="flex h-11 items-center justify-center gap-2 border-t border-zinc-200 text-xs text-zinc-500 transition-colors hover:bg-zinc-50 hover:text-zinc-900 dark:border-zinc-800 dark:text-zinc-400 dark:hover:bg-zinc-800/60 dark:hover:text-white"
        phx-click={JS.dispatch("phx:toggle-sidebar")}
        title="Fold or unfold the menu"
        aria-label="Fold or unfold the menu"
      >
        <.icon
          name="hero-chevron-double-left-mini"
          class="size-4 [[data-sidebar=collapsed]_&]:hidden"
        />
        <.icon
          name="hero-chevron-double-right-mini"
          class="hidden size-4 [[data-sidebar=collapsed]_&]:block"
        />
        <span class="[[data-sidebar=collapsed]_&]:hidden">Fold</span>
      </button>
    </aside>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :current, :boolean, default: false

  defp sidebar_item(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      aria-current={@current && "page"}
      title={@label}
      class={[
        "flex h-10 items-center gap-3 rounded-lg px-3 text-sm font-medium transition-colors [[data-sidebar=collapsed]_&]:justify-center [[data-sidebar=collapsed]_&]:px-0",
        @current && "bg-orange-50 text-orange-700 dark:bg-orange-500/10 dark:text-orange-300",
        !@current &&
          "text-zinc-600 hover:bg-zinc-100 hover:text-zinc-900 dark:text-zinc-400 dark:hover:bg-zinc-800 dark:hover:text-white"
      ]}
    >
      <.icon name={@icon} class="size-5 shrink-0" />
      <span class="truncate [[data-sidebar=collapsed]_&]:hidden">{@label}</span>
    </.link>
    """
  end

  @doc "The title of a screen, what it shows, and what can be done from it."
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :actions

  def page_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-end justify-between gap-4">
      <div>
        <h1 class="text-2xl font-semibold tracking-tight">{@title}</h1>
        <p :if={@subtitle} class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">{@subtitle}</p>
      </div>
      <div :if={@actions != []} class="flex flex-wrap items-center gap-3">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc "A surface for a group of things."
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <div
      class={[
        "rounded-2xl border border-zinc-200 bg-white shadow-sm shadow-zinc-900/[0.03] dark:border-zinc-800 dark:bg-zinc-900",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The title of a panel, what it holds, and what can be done with it."
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :actions

  def panel_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-3 border-b border-zinc-200 px-5 py-4 dark:border-zinc-800">
      <div>
        <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
          {@title}
        </h2>
        <p :if={@subtitle} class="mt-0.5 text-sm text-zinc-500 dark:text-zinc-400">{@subtitle}</p>
      </div>
      <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc "A labelled value, in a `<dl>`."
  attr :label, :string, required: true
  attr :rest, :global
  slot :inner_block, required: true

  def kv(assigns) do
    ~H"""
    <div {@rest}>
      <dt class="text-xs text-zinc-500 dark:text-zinc-400">{@label}</dt>
      <dd class="mt-1 text-sm font-medium">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  @doc "A small label: a country, a reason code, an outcome. The tone says how it went."
  attr :tone, :string, default: "zinc", values: ~w(zinc emerald amber rose sky violet)
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def tag(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex items-center rounded-md px-1.5 py-0.5 text-xs font-medium",
        tone_classes(@tone),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp tone_classes("zinc"), do: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"

  defp tone_classes("emerald"),
    do: "bg-emerald-50 text-emerald-700 dark:bg-emerald-500/10 dark:text-emerald-300"

  defp tone_classes("amber"),
    do: "bg-amber-50 text-amber-700 dark:bg-amber-500/10 dark:text-amber-300"

  defp tone_classes("rose"), do: "bg-rose-50 text-rose-700 dark:bg-rose-500/10 dark:text-rose-300"
  defp tone_classes("sky"), do: "bg-sky-50 text-sky-700 dark:bg-sky-500/10 dark:text-sky-300"

  defp tone_classes("violet"),
    do: "bg-violet-50 text-violet-700 dark:bg-violet-500/10 dark:text-violet-300"

  @doc "A labelled input or select of a form."
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text", values: ~w(text email password select)
  attr :options, :list, default: []
  attr :prompt, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(autocomplete inputmode placeholder required disabled)

  def field(%{type: "select"} = assigns) do
    assigns = assign(assigns, :errors, Enum.map(assigns.field.errors, &translate_error/1))

    ~H"""
    <label class={["block", @class]}>
      <span class="mb-1.5 block text-xs font-medium text-zinc-600 dark:text-zinc-400">{@label}</span>
      <span class="relative block">
        <select
          id={@field.id}
          name={@field.name}
          class={[
            "h-10 w-full appearance-none rounded-lg border bg-white pl-3 pr-9 text-sm shadow-sm transition-colors",
            "focus:outline-none focus:ring-2 focus:ring-orange-500/30 dark:bg-zinc-900",
            @errors == [] && "border-zinc-300 focus:border-orange-500 dark:border-zinc-700",
            @errors != [] && "border-rose-400 focus:border-rose-500"
          ]}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @field.value)}
        </select>
        <.icon
          name="hero-chevron-down-mini"
          class="pointer-events-none absolute right-2.5 top-1/2 size-4 -translate-y-1/2 text-zinc-400"
        />
      </span>
      <.field_errors errors={@errors} />
    </label>
    """
  end

  def field(assigns) do
    assigns = assign(assigns, :errors, Enum.map(assigns.field.errors, &translate_error/1))

    ~H"""
    <label class={["block", @class]}>
      <span class="mb-1.5 block text-xs font-medium text-zinc-600 dark:text-zinc-400">{@label}</span>
      <input
        type={@type}
        id={@field.id}
        name={@field.name}
        value={Phoenix.HTML.Form.normalize_value(@type, @field.value)}
        class={[
          "h-10 w-full rounded-lg border bg-white px-3 text-sm shadow-sm transition-colors placeholder:text-zinc-400",
          "focus:outline-none focus:ring-2 focus:ring-orange-500/30 dark:bg-zinc-900 dark:placeholder:text-zinc-500",
          @errors == [] && "border-zinc-300 focus:border-orange-500 dark:border-zinc-700",
          @errors != [] && "border-rose-400 focus:border-rose-500"
        ]}
        {@rest}
      />
      <.field_errors errors={@errors} />
    </label>
    """
  end

  attr :errors, :list, required: true

  defp field_errors(assigns) do
    ~H"""
    <p
      :for={error <- @errors}
      class="mt-1 flex items-center gap-1 text-xs text-rose-600 dark:text-rose-400"
    >
      <.icon name="hero-exclamation-circle-mini" class="size-3.5" /> {error}
    </p>
    """
  end

  @doc "A button, or a link that looks like one: the main action of a screen, or a quiet one."
  attr :variant, :string, default: "quiet", values: ~w(primary quiet)
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(href navigate patch method type disabled phx-disable-with form)
  slot :inner_block, required: true

  def action(assigns) do
    assigns =
      assign(assigns, :classes, [
        "inline-flex h-10 items-center justify-center gap-2 rounded-lg px-4 text-sm font-medium shadow-sm transition",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-orange-500/40 active:translate-y-px disabled:pointer-events-none disabled:opacity-60",
        assigns.variant == "primary" && "bg-orange-600 text-white hover:bg-orange-500",
        assigns.variant == "quiet" &&
          "border border-zinc-300 bg-white text-zinc-700 hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-200 dark:hover:bg-zinc-800",
        assigns.class
      ])

    ~H"""
    <%= if @rest[:href] || @rest[:navigate] || @rest[:patch] do %>
      <.link class={@classes} {@rest}>{render_slot(@inner_block)}</.link>
    <% else %>
      <button class={@classes} {@rest}>{render_slot(@inner_block)}</button>
    <% end %>
    """
  end

  @doc "An application's state, at a glance."
  attr :state, :atom, required: true

  def state_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full py-0.5 pl-1.5 pr-2.5 text-xs font-medium ring-1 ring-inset",
      state_classes(@state)
    ]}>
      <span class={["size-1.5 rounded-full", dot_classes(@state)]} />
      {@state |> Atom.to_string() |> String.replace("_", " ")}
    </span>
    """
  end

  @doc "A small sign that the screen follows changes as they happen."
  def live_dot(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 text-xs text-zinc-500 dark:text-zinc-400">
      <span class="relative flex size-2">
        <span class="absolute inline-flex size-full animate-ping rounded-full bg-emerald-400 opacity-60" />
        <span class="relative inline-flex size-2 rounded-full bg-emerald-500" />
      </span>
      Live
    </span>
    """
  end

  @doc "What a screen shows when there is nothing to show yet."
  attr :icon, :string, default: "hero-inbox"
  attr :title, :string, required: true
  attr :text, :string, default: nil
  attr :rest, :global

  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center px-6 py-16 text-center" {@rest}>
      <span class="flex size-12 items-center justify-center rounded-full bg-zinc-100 text-zinc-400 dark:bg-zinc-800 dark:text-zinc-500">
        <.icon name={@icon} class="size-6" />
      </span>
      <p class="mt-4 text-sm font-medium">{@title}</p>
      <p :if={@text} class="mt-1 max-w-sm text-sm text-zinc-500 dark:text-zinc-400">{@text}</p>
    </div>
    """
  end

  @doc "System, light or dark: the theme the page follows, remembered in the browser."
  attr :labels, :boolean, default: false

  def theme_switch(assigns) do
    assigns =
      assign(assigns, :themes, [
        {"system", "hero-computer-desktop", "System", "Follows the device's setting"},
        {"light", "hero-sun", "Light", "Always light"},
        {"dark", "hero-moon", "Dark", "Always dark"}
      ])

    ~H"""
    <div
      id="theme-switch"
      class={[
        "grid gap-2",
        @labels && "sm:grid-cols-3",
        !@labels && "grid-cols-3"
      ]}
    >
      <button
        :for={{theme, icon, name, text} <- @themes}
        type="button"
        class={[
          "flex items-center gap-3 rounded-xl border px-3 py-2.5 text-left text-sm transition-colors",
          "border-zinc-200 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800",
          theme_current(theme)
        ]}
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
        title={name}
        aria-label={name}
      >
        <.icon name={icon} class="size-5 shrink-0 text-zinc-500 dark:text-zinc-400" />
        <span :if={@labels} class="leading-tight">
          <span class="block font-medium">{name}</span>
          <span class="block text-xs text-zinc-500 dark:text-zinc-400">{text}</span>
        </span>
      </button>
    </div>
    """
  end

  # The chosen theme stands out, through the attributes the page keeps on <html>
  defp theme_current("system"),
    do:
      "[[data-theme-source=system]_&]:border-orange-400 [[data-theme-source=system]_&]:ring-2 [[data-theme-source=system]_&]:ring-orange-500/30"

  defp theme_current("light"),
    do:
      "[[data-theme-source=user][data-theme=light]_&]:border-orange-400 [[data-theme-source=user][data-theme=light]_&]:ring-2 [[data-theme-source=user][data-theme=light]_&]:ring-orange-500/30"

  defp theme_current("dark"),
    do:
      "[[data-theme-source=user][data-theme=dark]_&]:border-orange-400 [[data-theme-source=user][data-theme=dark]_&]:ring-2 [[data-theme-source=user][data-theme=dark]_&]:ring-orange-500/30"

  defp initials(email) do
    email |> to_string() |> String.split("@") |> List.first() |> String.slice(0, 2)
  end

  defp scope_labels(%{global_role: role}) when not is_nil(role), do: [Atom.to_string(role)]
  defp scope_labels(%{countries: countries}), do: countries

  defp state_classes(:approved),
    do:
      "bg-emerald-50 text-emerald-700 ring-emerald-600/20 dark:bg-emerald-500/10 dark:text-emerald-300 dark:ring-emerald-400/20"

  defp state_classes(:rejected),
    do:
      "bg-rose-50 text-rose-700 ring-rose-600/20 dark:bg-rose-500/10 dark:text-rose-300 dark:ring-rose-400/20"

  defp state_classes(:cancelled),
    do:
      "bg-zinc-100 text-zinc-600 ring-zinc-500/20 dark:bg-zinc-800 dark:text-zinc-300 dark:ring-zinc-500/30"

  defp state_classes(:provider_error),
    do:
      "bg-red-50 text-red-700 ring-red-600/20 dark:bg-red-500/10 dark:text-red-300 dark:ring-red-400/20"

  defp state_classes(state) when state in [:in_review, :info_requested],
    do:
      "bg-amber-50 text-amber-700 ring-amber-600/20 dark:bg-amber-500/10 dark:text-amber-300 dark:ring-amber-400/20"

  defp state_classes(:pending_countersign),
    do:
      "bg-violet-50 text-violet-700 ring-violet-600/20 dark:bg-violet-500/10 dark:text-violet-300 dark:ring-violet-400/20"

  defp state_classes(_moving),
    do:
      "bg-sky-50 text-sky-700 ring-sky-600/20 dark:bg-sky-500/10 dark:text-sky-300 dark:ring-sky-400/20"

  defp dot_classes(:approved), do: "bg-emerald-500"
  defp dot_classes(:rejected), do: "bg-rose-500"
  defp dot_classes(:cancelled), do: "bg-zinc-400"
  defp dot_classes(:provider_error), do: "bg-red-500"
  defp dot_classes(state) when state in [:in_review, :info_requested], do: "bg-amber-500"
  defp dot_classes(:pending_countersign), do: "bg-violet-500"
  defp dot_classes(_moving), do: "bg-sky-500 animate-pulse"
end
