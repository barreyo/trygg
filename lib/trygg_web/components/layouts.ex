defmodule TryggWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use TryggWeb, :html

  alias Trygg.Families.Child

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app shell: a compact top bar, the page content in a phone-width
  column with safe-area padding, and a bottom tab bar for thumb navigation.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope}>
        <h1>Content</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :current_child, :map, default: nil, doc: "the active child, when on a child-scoped page"

  attr :children, :list,
    default: [],
    doc: "children the user can switch between; the switcher shows when there are two or more"

  attr :child_switch_to, :atom,
    default: :home,
    values: [:home, :log, :vitals, :reports, :caregivers],
    doc: "which child page a switch should land on"

  attr :title, :string, default: nil, doc: "heading shown in the top bar"
  attr :subtitle, :string, default: nil, doc: "smaller line under the title, e.g. the child's age"
  attr :back, :string, default: nil, doc: "optional path for a back arrow in the top bar"

  slot :inner_block, required: true
  slot :actions, doc: "optional controls rendered at the right of the top bar"

  def app(assigns) do
    assigns = assign(assigns, :child_switcher, child_switcher_kind(assigns))

    ~H"""
    <div class="min-h-dvh flex flex-col bg-base-100 text-base-content">
      <header class="sticky top-0 z-30 bg-base-100/90 backdrop-blur border-b border-base-300 pt-[env(safe-area-inset-top)]">
        <div class="mx-auto max-w-md w-full flex items-center gap-2 px-4 min-h-14 py-1.5">
          <.button
            :if={@back}
            variant="ghost"
            size="sm"
            navigate={@back}
            class="btn-circle -ml-2"
            aria-label="Back"
          >
            <.icon name="hero-chevron-left" class="size-5" />
          </.button>
          <.child_switcher
            :if={@child_switcher == :full}
            variant={:full}
            current_child={@current_child}
            children={@children}
            child_switch_to={@child_switch_to}
          />
          <div :if={@child_switcher != :full} class="flex-1 min-w-0 leading-tight">
            <div class="font-semibold text-lg truncate">
              {@title || "Trygg"}
            </div>
            <div :if={@subtitle} class="text-xs opacity-60 truncate">
              {@subtitle}
            </div>
          </div>
          {render_slot(@actions)}
          <.child_switcher
            :if={@child_switcher == :compact}
            variant={:compact}
            current_child={@current_child}
            children={@children}
            child_switch_to={@child_switch_to}
          />
          <.app_menu :if={@current_scope && @current_scope.user} />
        </div>
      </header>

      <main class="flex-1 mx-auto max-w-md w-full px-4 py-4 pb-28">
        {render_slot(@inner_block)}
      </main>

      <.bottom_nav :if={@current_scope && @current_scope.user} current_child={@current_child} />

      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :current_child, :map, default: nil

  defp bottom_nav(assigns) do
    ~H"""
    <nav class="fixed bottom-0 inset-x-0 z-30 bg-base-200 border-t border-base-300 pb-[env(safe-area-inset-bottom)]">
      <div class="mx-auto max-w-md grid grid-cols-4 text-center text-xs">
        <%= if @current_child do %>
          <.nav_item navigate={~p"/c/#{@current_child}"} icon="hero-home" label="Home" />
          <.nav_item navigate={~p"/c/#{@current_child}/log"} icon="hero-list-bullet" label="Log" />
          <.nav_item navigate={~p"/c/#{@current_child}/vitals"} icon="hero-heart" label="Vitals" />
          <.nav_item
            navigate={~p"/c/#{@current_child}/reports"}
            icon="hero-chart-bar"
            label="Reports"
          />
        <% else %>
          <.nav_item navigate={~p"/"} icon="hero-home" label="Children" />
          <.nav_item navigate={~p"/preferences"} icon="hero-adjustments-horizontal" label="Units" />
          <.nav_item navigate={~p"/users/settings"} icon="hero-cog-6-tooth" label="Account" />
          <.nav_item
            href={~p"/users/log-out"}
            method="delete"
            icon="hero-arrow-left-start-on-rectangle"
            label="Log out"
          />
        <% end %>
      </div>
    </nav>
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :rest, :global, include: ~w(navigate href method)

  defp nav_item(assigns) do
    ~H"""
    <.link
      {@rest}
      class="flex flex-col items-center gap-1 py-2.5 hover:bg-base-300 active:bg-base-300 transition-colors"
    >
      <.icon name={@icon} class="size-6" />
      <span>{@label}</span>
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  defp child_switcher_kind(%{current_child: %{id: _}, children: children, back: back})
       when is_list(children) do
    if match?([_, _ | _], children) do
      if back, do: :compact, else: :full
    end
  end

  defp child_switcher_kind(_assigns), do: nil

  attr :variant, :atom, required: true, values: [:full, :compact]
  attr :current_child, :map, required: true
  attr :children, :list, required: true
  attr :child_switch_to, :atom, required: true

  defp child_switcher(assigns) do
    assigns =
      assign(assigns, :age, Child.age_label(assigns.current_child))

    ~H"""
    <div
      id="child-switcher"
      class={[
        "dropdown",
        @variant == :full && "flex-1 min-w-0",
        @variant == :compact && "dropdown-end shrink-0"
      ]}
    >
      <button
        :if={@variant == :full}
        type="button"
        tabindex="0"
        class="flex items-center gap-2.5 w-full min-h-12 -ml-1 pl-1 pr-2 rounded-lg text-left cursor-pointer select-none touch-manipulation hover:bg-base-200 active:bg-base-300 [-webkit-tap-highlight-color:transparent]"
        id="child-switcher-trigger"
        aria-haspopup="menu"
        aria-label={"Switch child, currently #{@current_child.name}"}
      >
        <span class="size-10 rounded-full bg-primary/15 text-primary grid place-items-center font-semibold shrink-0">
          {child_initial(@current_child)}
        </span>
        <span class="flex-1 min-w-0 leading-tight">
          <span class="font-semibold text-lg truncate flex items-center gap-1">
            <span class="truncate">{@current_child.name}</span>
            <.icon name="hero-chevron-down" class="size-4 opacity-50 shrink-0" />
          </span>
          <span class="text-xs opacity-60 truncate block">
            {@age || "Tap to switch child"}
          </span>
        </span>
      </button>

      <button
        :if={@variant == :compact}
        type="button"
        tabindex="0"
        class="flex items-center gap-1.5 max-w-36 h-10 pl-1 pr-2 rounded-full border border-base-300 bg-base-200 cursor-pointer select-none touch-manipulation hover:bg-base-300 active:scale-[.97] [-webkit-tap-highlight-color:transparent]"
        id="child-switcher-trigger"
        aria-haspopup="menu"
        aria-label={"Switch child, currently #{@current_child.name}"}
      >
        <span class="size-7 rounded-full bg-primary/15 text-primary grid place-items-center text-xs font-semibold shrink-0">
          {child_initial(@current_child)}
        </span>
        <span class="font-medium text-sm truncate">{@current_child.name}</span>
        <.icon name="hero-chevron-down" class="size-3.5 opacity-50 shrink-0" />
      </button>

      <div
        tabindex="0"
        role="menu"
        aria-label="Switch child"
        class={[
          "dropdown-content bg-base-100 rounded-box z-40 mt-1 p-1.5 shadow-lg border border-base-300",
          @variant == :full && "w-full min-w-64",
          @variant == :compact && "w-72"
        ]}
      >
        <p class="px-2.5 pt-1.5 pb-1 text-xs font-medium uppercase tracking-wide opacity-50">
          Switch child
        </p>
        <.link
          :for={c <- @children}
          id={"child-switcher-#{c.id}"}
          navigate={child_path(c, @child_switch_to)}
          role="menuitem"
          aria-current={c.id == @current_child.id && "page"}
          class={[
            "flex items-center gap-3 rounded-box px-2 py-2 min-h-12",
            "hover:bg-base-200 active:bg-base-300",
            c.id == @current_child.id && "bg-primary/10"
          ]}
        >
          <span class={[
            "size-10 rounded-full grid place-items-center font-semibold shrink-0",
            c.id == @current_child.id && "bg-primary text-primary-content",
            c.id != @current_child.id && "bg-primary/15 text-primary"
          ]}>
            {child_initial(c)}
          </span>
          <span class="flex-1 min-w-0 leading-tight">
            <span class="font-semibold truncate block">{c.name}</span>
            <span :if={Child.age_label(c)} class="text-sm opacity-60 truncate block">
              {Child.age_label(c)}
            </span>
          </span>
          <.icon
            :if={c.id == @current_child.id}
            name="hero-check"
            class="size-5 text-primary shrink-0"
          />
        </.link>
      </div>
    </div>
    """
  end

  defp child_path(child, :home), do: ~p"/c/#{child}"
  defp child_path(child, :log), do: ~p"/c/#{child}/log"
  defp child_path(child, :vitals), do: ~p"/c/#{child}/vitals"
  defp child_path(child, :reports), do: ~p"/c/#{child}/reports"
  defp child_path(child, :caregivers), do: ~p"/c/#{child}/caregivers"
  defp child_path(child, _), do: ~p"/c/#{child}"

  defp child_initial(%{name: name}) when is_binary(name) do
    case String.trim(name) do
      "" -> "?"
      trimmed -> String.first(trimmed)
    end
  end

  defp app_menu(assigns) do
    ~H"""
    <div id="app-menu" class="dropdown dropdown-end">
      <.button
        tabindex="0"
        type="button"
        variant="ghost"
        size="sm"
        class="btn-circle"
        aria-label="Menu"
      >
        <.icon name="hero-ellipsis-vertical" class="size-5" />
      </.button>
      <ul tabindex="0" class="dropdown-content menu bg-base-200 rounded-box z-40 w-52 p-2 shadow">
        <li>
          <.link id="app-menu-children" navigate={~p"/children"}>
            <.icon name="hero-users" class="size-4" /> Children
          </.link>
        </li>
        <li>
          <.link id="app-menu-preferences" navigate={~p"/preferences"}>
            <.icon name="hero-adjustments-horizontal" class="size-4" /> Preferences
          </.link>
        </li>
      </ul>
    </div>
    """
  end
end
