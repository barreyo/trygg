defmodule TryggWeb.CaregiverLive do
  use TryggWeb, :live_view

  alias Trygg.Families

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_child={@current_child}
      children={@children}
      child_switch_to={:caregivers}
      title="Sharing"
      back={~p"/c/#{@current_child}"}
    >
      <.header>
        {@current_child.name}'s caregivers
        <:subtitle>Everyone here sees the same log, live.</:subtitle>
      </.header>

      <ul class="mt-4 divide-y divide-base-300 rounded-box border border-base-300 bg-base-200">
        <li :for={m <- @members} class="flex items-center gap-3 p-3">
          <div class="size-9 rounded-full bg-base-300 grid place-items-center text-sm">
            {String.first(m.user.email)}
          </div>
          <div class="flex-1 min-w-0">
            <div class="truncate">
              {m.user.email}
              <span :if={m.user_id == @current_scope.user.id} class="opacity-50">(you)</span>
            </div>
            <div class="text-xs opacity-60">{m.role}</div>
          </div>
          <.button
            :if={@is_owner and m.user_id != @current_scope.user.id}
            type="button"
            variant="ghost"
            size="xs"
            phx-click="remove_member"
            phx-value-id={m.id}
            data-confirm={"Remove #{m.user.email}?"}
            aria-label="Remove"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </.button>
        </li>
      </ul>

      <%= if @is_owner do %>
        <div :if={@invites != []} class="mt-6">
          <h3 class="text-sm font-semibold opacity-70 mb-2">Pending invites</h3>
          <ul class="divide-y divide-base-300 rounded-box border border-base-300 bg-base-200">
            <li :for={i <- @invites} class="flex items-center gap-3 p-3">
              <.icon name="hero-envelope" class="size-5 opacity-50" />
              <div class="flex-1 min-w-0">
                <div class="truncate">{i.email}</div>
                <div class="text-xs opacity-60">
                  {i.role} · invited {relative_time(i.inserted_at)}
                </div>
              </div>
              <.button
                type="button"
                variant="ghost"
                size="xs"
                phx-click="revoke_invite"
                phx-value-id={i.id}
              >
                Revoke
              </.button>
            </li>
          </ul>
        </div>

        <div class="mt-6">
          <h3 class="text-sm font-semibold opacity-70 mb-2">Invite a caregiver</h3>
          <.form for={@form} id="invite-form" phx-submit="invite" class="space-y-3">
            <.input
              field={@form[:email]}
              type="email"
              placeholder="their@email.com"
              autocomplete="off"
            />
            <.input
              field={@form[:role]}
              type="select"
              options={[{"Caregiver — can log", :caregiver}, {"Viewer — read only", :viewer}]}
            />
            <.button variant="primary" phx-disable-with="Sending…" class="w-full">
              Send invite
            </.button>
          </.form>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Trygg.Accounts.subscribe_user(socket.assigns.current_scope.user.id)

    {:ok, load(socket)}
  end

  @impl true
  def handle_info({tag, _child_id}, socket)
      when tag in [:members_changed, :invites_changed] do
    scope = socket.assigns.current_scope
    child = socket.assigns.current_child

    case Families.member_role(scope, child) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "You no longer have access to #{child.name}.")
         |> push_navigate(to: ~p"/")}

      role ->
        {:noreply,
         socket
         |> assign(:role, role)
         |> assign(:current_child, %{child | role: role})
         |> load()}
    end
  end

  def handle_info({:child_updated, child}, socket) do
    {:noreply, assign(socket, :current_child, %{child | role: socket.assigns.role})}
  end

  def handle_info({:child_born, child}, socket) do
    {:noreply, assign(socket, :current_child, %{child | role: socket.assigns.role})}
  end

  def handle_info({:child_deleted, _child_id}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "#{socket.assigns.current_child.name} was deleted.")
     |> push_navigate(to: ~p"/")}
  end

  def handle_info({:user_updated, user}, socket) do
    {:noreply,
     socket
     |> assign(:current_scope, %{socket.assigns.current_scope | user: user})
     |> load()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("invite", %{"invite" => params}, socket) do
    scope = socket.assigns.current_scope
    child = socket.assigns.current_child
    url_fun = fn token -> url(~p"/invites/#{token}") end

    case Families.invite_caregiver(scope, child, params, url_fun) do
      {:ok, invite} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invite sent to #{invite.email}.")
         |> push_navigate(to: ~p"/c/#{child}/caregivers")}

      {:error, :already_member} ->
        {:noreply, put_flash(socket, :error, "That person is already a caregiver.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("revoke_invite", %{"id" => id}, socket) do
    invite = Enum.find(socket.assigns.invites, &(&1.id == String.to_integer(id)))
    if invite, do: Families.revoke_invite(socket.assigns.current_scope, invite)
    {:noreply, load(socket)}
  end

  def handle_event("remove_member", %{"id" => id}, socket) do
    member = Enum.find(socket.assigns.members, &(&1.id == String.to_integer(id)))

    socket =
      case member &&
             Families.remove_member(
               socket.assigns.current_scope,
               socket.assigns.current_child,
               member
             ) do
        {:ok, _} -> put_flash(socket, :info, "Caregiver removed.")
        {:error, :last_owner} -> put_flash(socket, :error, "Can't remove the last owner.")
        _ -> socket
      end

    {:noreply, load(socket)}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    child = socket.assigns.current_child
    is_owner = child.role == :owner

    socket
    |> assign(:members, Families.list_members(scope, child))
    |> assign(:is_owner, is_owner)
    |> assign(:invites, if(is_owner, do: Families.list_invites(scope, child), else: []))
    |> assign_new(:form, fn -> to_form(Families.change_invite()) end)
  end
end
