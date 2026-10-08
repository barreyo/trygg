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

  On larger screens child pages trade the bottom tab bar for a sidebar (`lg`),
  and pages that pass `wide` get a wider column (from `md`) to lay their cards
  out side by side — see `columns/1`.

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

  attr :current_tab, :atom,
    default: nil,
    values: [nil, :home, :log, :vitals, :reports],
    doc: "which bottom tab (if any) to highlight as active"

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

  attr :wide, :boolean,
    default: false,
    doc: "widen the content column on tablet/desktop, for pages laid out with `columns/1`"

  attr :immersive, :boolean,
    default: false,
    doc:
      "drop the top bar so the page can paint its own full-bleed background (the signed-out login screen)"

  slot :inner_block, required: true
  slot :actions, doc: "optional controls rendered at the right of the top bar"

  def app(assigns) do
    assigns = assign(assigns, :child_switcher, child_switcher_kind(assigns))

    assigns =
      if assigns.child_switcher do
        assigns
        |> assign(:swipe_prev, sibling_child(assigns.children, assigns.current_child, -1))
        |> assign(:swipe_next, sibling_child(assigns.children, assigns.current_child, 1))
      else
        assigns
        |> assign(:swipe_prev, nil)
        |> assign(:swipe_next, nil)
      end

    assigns =
      assign(assigns, :column_class, [
        "mx-auto w-full max-w-md",
        assigns.wide && "md:max-w-5xl"
      ])

    ~H"""
    <div class={[
      "min-h-dvh flex flex-col bg-base-100 text-base-content",
      @current_child && "lg:pl-60"
    ]}>
      <.side_nav
        :if={@current_child}
        current_child={@current_child}
        current_tab={@current_tab}
      />

      <header
        :if={!@immersive}
        class="sticky top-0 z-30 bg-base-100/90 backdrop-blur border-b border-base-300 pt-[env(safe-area-inset-top)]"
      >
        <div class={[@column_class, "flex items-center gap-2 px-4 min-h-14 py-1.5"]}>
          <%!-- On a tab page the back arrow only leads Home, which the sidebar
               already offers on desktop. --%>
          <.button
            :if={@back}
            variant="ghost"
            size="sm"
            navigate={@back}
            class={["btn-circle -ml-2", @current_tab && "lg:hidden"]}
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
          <.app_menu :if={@current_scope && @current_scope.user} current_child={@current_child} />
        </div>
      </header>

      <%!-- Revealed edge-first by the `ChildSwipe` hook as <main> is dragged,
           so a mid-swipe glance already shows who you'd land on. Also used
           to play the one-time swipe hint (see the hook). --%>
      <.child_swipe_peek
        :if={@swipe_prev}
        id="child-swipe-peek-prev"
        side={:left}
        child={@swipe_prev}
      />
      <.child_swipe_peek
        :if={@swipe_next}
        id="child-swipe-peek-next"
        side={:right}
        child={@swipe_next}
      />

      <main
        id="main-content"
        phx-hook={@child_switcher && "ChildSwipe"}
        class={[
          @column_class,
          "flex-1 px-4 py-4",
          if(@current_child, do: "pb-28 lg:pb-8", else: "pb-8"),
          @immersive && "pt-[max(1rem,env(safe-area-inset-top))]"
        ]}
      >
        <.demo_banner :if={@current_child && Child.expecting?(@current_child)} child={@current_child} />
        {render_slot(@inner_block)}
        <%!-- Kept last so it never pushes a page's own content (vital stats,
             alerts, …) down the screen — it reads as a footer-level nudge,
             not something competing for the top of the page. --%>
        <.install_prompt :if={@current_scope && @current_scope.user} />
      </main>

      <%!-- The tab bar (sidebar on desktop) is child-scoped. Account-level pages
           (children, preferences, account) are secondary screens reached from
           the ⋮ menu and exited via the back arrow, so they don't show a tab bar. --%>
      <.bottom_nav
        :if={@current_child}
        current_child={@current_child}
        current_tab={@current_tab}
      />

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Lays a `wide` page out in two columns from `md` up, each about a phone's
  width so cards and charts keep the proportions they were designed for. On
  phones the columns simply stack, left first.

  The columns are separate grid cells, so a top margin on the first block of
  `right` no longer collapses away — zero it from `md` (`md:mt-0`).

  ## Examples

      <Layouts.columns id="vitals-columns">
        <:left>…stats…</:left>
        <:right>…charts…</:right>
      </Layouts.columns>
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :left, required: true
  slot :right, required: true

  def columns(assigns) do
    ~H"""
    <div id={@id} class={["md:grid md:grid-cols-2 md:items-start md:gap-6", @class]}>
      <div class="min-w-0">{render_slot(@left)}</div>
      <div class="min-w-0">{render_slot(@right)}</div>
    </div>
    """
  end

  # Shown on every child screen while a child is still "expecting": the app is
  # fully usable, but everything logged is practice and gets wiped once the baby
  # arrives. Owners get a shortcut straight to confirming the birth date.
  attr :child, :map, required: true

  defp demo_banner(assigns) do
    ~H"""
    <div class="mb-4 flex items-start gap-3 rounded-box border border-warning/40 bg-warning/10 p-3 text-sm">
      <.icon name="hero-sparkles" class="size-5 shrink-0 mt-0.5 text-warning" />
      <div class="flex-1 min-w-0 space-y-2">
        <p class="font-medium">
          Expecting {@child.name} — {Child.due_label(@child)}
        </p>
        <p class="opacity-70">
          Try everything out now. Anything you track is just practice and clears the moment {@child.name} arrives.
        </p>
        <.button
          :if={@child.role == :owner}
          size="sm"
          variant="warning"
          navigate={~p"/children/#{@child}/edit?#{[arrived: 1]}"}
        >
          {@child.name} has arrived
        </.button>
      </div>
    </div>
    """
  end

  # Rendered hidden; the InstallPrompt hook decides which variant (if any) to
  # show based on platform, install state and a localStorage dismissal.
  defp install_prompt(assigns) do
    ~H"""
    <div
      id="install-prompt"
      phx-hook="InstallPrompt"
      phx-update="ignore"
      hidden
      class="mt-6 flex items-start gap-3 rounded-box border border-base-300 bg-base-200 p-3 text-sm"
    >
      <.icon name="hero-device-phone-mobile" class="size-5 shrink-0 mt-0.5 text-primary" />
      <div class="flex-1 min-w-0 space-y-2">
        <div data-install-ios hidden>
          <p class="font-medium">Add Trygg to your Home Screen</p>
          <p class="opacity-70">
            Tap <.icon name="hero-arrow-up-on-square" class="size-4 inline-block align-text-bottom" />
            Share, then <span class="font-medium">Add to Home Screen</span>
            to open it like an app.
          </p>
        </div>
        <div data-install-android hidden class="flex items-center justify-between gap-3">
          <p class="font-medium">Install Trygg as an app</p>
          <.button
            id="install-prompt-install"
            type="button"
            variant="primary"
            size="sm"
            data-install-action="install"
          >
            Install
          </.button>
        </div>
      </div>
      <button
        id="install-prompt-dismiss"
        type="button"
        class="btn btn-ghost btn-xs btn-circle -mr-1 -mt-1"
        aria-label="Dismiss"
        data-install-action="dismiss"
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </div>
    """
  end

  attr :current_child, :map, required: true
  attr :current_tab, :atom, default: nil

  defp bottom_nav(assigns) do
    ~H"""
    <nav
      id="bottom-nav"
      class="fixed bottom-0 inset-x-0 z-30 bg-base-200 border-t border-base-300 pb-[env(safe-area-inset-bottom)] lg:hidden"
    >
      <div class="mx-auto max-w-md md:max-w-lg grid grid-cols-4 text-center text-xs">
        <.nav_item
          navigate={~p"/c/#{@current_child}"}
          icon="hero-home"
          active_icon="hero-home-solid"
          label="Home"
          active={@current_tab == :home}
        />
        <.nav_item
          navigate={~p"/c/#{@current_child}/log"}
          icon="hero-list-bullet"
          active_icon="hero-list-bullet-solid"
          label="Log"
          active={@current_tab == :log}
        />
        <.nav_item
          navigate={~p"/c/#{@current_child}/vitals"}
          icon="hero-heart"
          active_icon="hero-heart-solid"
          label="Vitals"
          active={@current_tab == :vitals}
        />
        <.nav_item
          navigate={~p"/c/#{@current_child}/reports"}
          icon="hero-chart-bar"
          active_icon="hero-chart-bar-solid"
          label="Reports"
          active={@current_tab == :reports}
        />
      </div>
    </nav>
    """
  end

  # Desktop counterpart of `bottom_nav/1`: the same four tabs down a fixed left
  # rail, since a bar pinned to the bottom of a wide screen is a long way from
  # everything else.
  attr :current_child, :map, required: true
  attr :current_tab, :atom, default: nil

  defp side_nav(assigns) do
    ~H"""
    <nav
      id="side-nav"
      class="hidden lg:flex fixed inset-y-0 left-0 z-30 w-60 flex-col border-r border-base-300 bg-base-200 pt-[env(safe-area-inset-top)]"
    >
      <.link
        navigate={~p"/c/#{@current_child}"}
        class="flex items-center gap-2.5 px-5 min-h-14 py-1.5 border-b border-base-300 font-semibold text-lg"
      >
        <img src={~p"/images/icon-192.png"} alt="" class="size-8 rounded-lg" /> Trygg
      </.link>
      <div class="flex flex-col gap-1 p-3">
        <.side_nav_item
          navigate={~p"/c/#{@current_child}"}
          icon="hero-home"
          active_icon="hero-home-solid"
          label="Home"
          active={@current_tab == :home}
        />
        <.side_nav_item
          navigate={~p"/c/#{@current_child}/log"}
          icon="hero-list-bullet"
          active_icon="hero-list-bullet-solid"
          label="Log"
          active={@current_tab == :log}
        />
        <.side_nav_item
          navigate={~p"/c/#{@current_child}/vitals"}
          icon="hero-heart"
          active_icon="hero-heart-solid"
          label="Vitals"
          active={@current_tab == :vitals}
        />
        <.side_nav_item
          navigate={~p"/c/#{@current_child}/reports"}
          icon="hero-chart-bar"
          active_icon="hero-chart-bar-solid"
          label="Reports"
          active={@current_tab == :reports}
        />
      </div>
    </nav>
    """
  end

  attr :icon, :string, required: true
  attr :active_icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :rest, :global, include: ~w(navigate href method)

  defp side_nav_item(assigns) do
    ~H"""
    <.link
      {@rest}
      aria-current={@active && "page"}
      data-nav-tab
      class={[
        "flex items-center gap-3 rounded-box px-3 py-2.5 transition-colors",
        if(@active,
          do: "bg-primary/10 text-primary font-semibold",
          else: "text-base-content/70 hover:bg-base-300 hover:text-base-content"
        )
      ]}
    >
      <.icon name={if @active, do: @active_icon, else: @icon} class="size-5" />
      {@label}
    </.link>
    """
  end

  attr :icon, :string, required: true
  attr :active_icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :rest, :global, include: ~w(navigate href method)

  defp nav_item(assigns) do
    ~H"""
    <.link
      {@rest}
      aria-current={@active && "page"}
      data-nav-tab
      class={[
        "relative flex flex-col items-center gap-1 py-2.5 transition-colors",
        "hover:bg-base-300 active:bg-base-300",
        if(@active, do: "text-primary", else: "text-base-content/60")
      ]}
    >
      <span
        :if={@active}
        class="absolute top-0 h-0.5 w-8 rounded-full bg-primary"
        aria-hidden="true"
      />
      <.icon name={if @active, do: @active_icon, else: @icon} class="size-6" />
      <span class={@active && "font-semibold"}>{@label}</span>
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

  # The child a left/right swipe would land on, wrapping around the list the
  # same way the `ChildSwipe` hook's `go/1` does.
  defp sibling_child(children, %{id: current_id}, offset) when is_list(children) do
    len = length(children)

    with true <- len >= 2,
         index when not is_nil(index) <- Enum.find_index(children, &(&1.id == current_id)) do
      Enum.at(children, rem(index + offset + len, len))
    else
      _ -> nil
    end
  end

  defp sibling_child(_children, _current_child, _offset), do: nil

  # Edge chip the `ChildSwipe` hook slides into view (by id) as <main> is
  # dragged, previewing the child a release would switch to. Hidden and
  # off-screen until the hook animates it.
  attr :id, :string, required: true
  attr :side, :atom, required: true, values: [:left, :right]
  attr :child, :map, required: true

  defp child_swipe_peek(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "fixed top-1/2 z-40 flex items-center gap-2 rounded-full border border-base-300 bg-base-100 py-2 pl-2 pr-3.5 shadow-lg opacity-0 pointer-events-none",
        @side == :left && "left-3",
        @side == :right && "right-3"
      ]}
      aria-hidden="true"
    >
      <span class="size-8 rounded-full bg-primary/15 text-primary grid place-items-center text-sm font-semibold shrink-0">
        {child_initial(@child)}
      </span>
      <span class="text-sm font-medium truncate max-w-28">{@child.name}</span>
    </div>
    """
  end

  attr :variant, :atom, required: true, values: [:full, :compact]
  attr :current_child, :map, required: true
  attr :children, :list, required: true
  attr :child_switch_to, :atom, required: true

  defp child_switcher(assigns) do
    assigns =
      assign(assigns, :age, Child.caption(assigns.current_child))

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
            <span :if={Child.caption(c)} class="text-sm opacity-60 truncate block">
              {Child.caption(c)}
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

  attr :current_child, :map, default: nil

  # On child pages the menu opens with that child's own actions (edit / sharing),
  # followed by the account-level ones. Editing is owner-only, matching
  # `Families.update_child/3`.
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
      <ul tabindex="0" class="dropdown-content menu bg-base-200 rounded-box z-40 w-56 p-2 shadow">
        <%= if @current_child do %>
          <li class="menu-title truncate">{@current_child.name}</li>
          <li :if={@current_child.role == :owner}>
            <.link id="app-menu-edit-child" navigate={~p"/children/#{@current_child}/edit"}>
              <.icon name="hero-pencil-square" class="size-4" /> Edit details
            </.link>
          </li>
          <li>
            <.link id="app-menu-sharing" navigate={~p"/c/#{@current_child}/caregivers"}>
              <.icon name="hero-user-group" class="size-4" /> Sharing
            </.link>
          </li>
        <% end %>
        <li class={@current_child && "border-t border-base-300 mt-1 pt-1"}>
          <.link id="app-menu-children" navigate={~p"/children"}>
            <.icon name="hero-users" class="size-4" /> Children
          </.link>
        </li>
        <li>
          <.link id="app-menu-preferences" navigate={~p"/preferences"}>
            <.icon name="hero-adjustments-horizontal" class="size-4" /> Preferences
          </.link>
        </li>
        <li>
          <.link id="app-menu-account" navigate={~p"/users/settings"}>
            <.icon name="hero-cog-6-tooth" class="size-4" /> Account
          </.link>
        </li>
        <li class="border-t border-base-300 mt-1 pt-1">
          <.link id="app-menu-log-out" href={~p"/users/log-out"} method="delete">
            <.icon name="hero-arrow-left-start-on-rectangle" class="size-4" /> Log out
          </.link>
        </li>
      </ul>
    </div>
    """
  end
end
