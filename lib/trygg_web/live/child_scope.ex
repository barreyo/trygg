defmodule TryggWeb.ChildScope do
  @moduledoc """
  `on_mount` hook that resolves the `:id` route param to a child the current
  user may see, assigns `@current_child` / `@role` / `@children`, folds the
  child onto the socket `scope`, and subscribes the LiveView to that child's
  realtime topic. `@children` is kept in sync when the user's set of children
  changes.

  No-ops for routes without an `:id` param (e.g. the child index or preferences).
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3, redirect: 2, attach_hook: 4]
  use TryggWeb, :verified_routes

  alias Trygg.Accounts.Scope
  alias Trygg.Families

  def on_mount(:assign_child, %{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    try do
      child = Families.get_child!(scope, id)
      if connected?(socket), do: Families.subscribe(child.id)

      socket =
        socket
        |> assign(:current_scope, Scope.put_child(scope, child, child.role))
        |> assign(:current_child, child)
        |> assign(:role, child.role)
        |> assign(:children, Families.list_children(scope))
        |> attach_hook(:sync_children, :handle_info, &sync_children_hook/2)

      {:cont, socket}
    rescue
      Ecto.NoResultsError ->
        {:halt,
         socket
         |> put_flash(
           :error,
           "We couldn't find that child — maybe it hasn't been shared with you yet."
         )
         |> redirect(to: ~p"/")}
    end
  end

  def on_mount(:assign_child, _params, _session, socket) do
    {:cont,
     socket
     |> assign(:current_child, nil)
     |> assign(:role, nil)
     |> assign(:children, [])}
  end

  defp sync_children_hook({:children_changed, _user_id}, socket) do
    {:halt, assign(socket, :children, Families.list_children(socket.assigns.current_scope))}
  end

  defp sync_children_hook(_msg, socket), do: {:cont, socket}
end
