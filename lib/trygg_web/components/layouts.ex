defmodule TryggWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use TryggWeb, :html

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
  attr :title, :string, default: nil, doc: "heading shown in the top bar"
  attr :back, :string, default: nil, doc: "optional path for a back arrow in the top bar"

  slot :inner_block, required: true
  slot :actions, doc: "optional controls rendered at the right of the top bar"

  def app(assigns) do
    ~H"""
    <div class="min-h-dvh flex flex-col bg-base-100 text-base-content">
      <header class="sticky top-0 z-30 bg-base-100/90 backdrop-blur border-b border-base-300 pt-[env(safe-area-inset-top)]">
        <div class="mx-auto max-w-md w-full flex items-center gap-2 px-4 h-14">
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
          <span class="font-semibold text-lg truncate flex-1">
            {@title || "Trygg"}
          </span>
          {render_slot(@actions)}
          <.theme_toggle />
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
        <.nav_item navigate={~p"/"} icon="hero-home" label="Children" />
        <%= if @current_child do %>
          <.nav_item navigate={~p"/c/#{@current_child}"} icon="hero-bolt" label="Today" />
          <.nav_item navigate={~p"/c/#{@current_child}/log"} icon="hero-list-bullet" label="Log" />
          <.nav_item
            navigate={~p"/c/#{@current_child}/caregivers"}
            icon="hero-users"
            label="Sharing"
          />
        <% else %>
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

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="System theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
