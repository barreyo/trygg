defmodule TryggWeb.CaregiverLive do
  use TryggWeb, :live_view

  alias Trygg.ApiTokens
  alias Trygg.Families
  alias TryggWeb.Loading

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
        <:subtitle>
          Everyone here sees the same log, live — for every child in this family.
        </:subtitle>
      </.header>

      <.loadable id="caregivers" loaded={@loaded?} failed={@load_failed?}>
        <:skeleton><.member_rows_skeleton /></:skeleton>
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

        <div :if={@is_owner and @invites != []} class="mt-6">
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
      </.loadable>

      <%= if @is_owner do %>
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

      <section id="api-access" class="mt-10">
        <h3 class="text-sm font-semibold opacity-70 mb-1">API access</h3>
        <p class="text-xs opacity-60 mb-3">
          A token lets a script or app read and log for this whole family over the
          REST API, as you. Send it as <code>Authorization: Bearer &lt;token&gt;</code>
          to <code>{url(~p"/api/v1/children")}</code>.
        </p>

        <div
          :if={@new_secret}
          id="new-api-token"
          class="rounded-box border border-success/40 bg-success/10 p-3 mb-4"
        >
          <p class="text-sm font-medium">Copy “{@new_secret.name}” now</p>
          <p class="text-xs opacity-70 mb-2">It won't be shown again.</p>
          <code
            id="new-api-token-secret"
            class="block break-all rounded bg-base-100 p-2 text-xs select-all"
          >
            {@new_secret.secret}
          </code>
          <.button
            type="button"
            variant="ghost"
            size="xs"
            phx-click="dismiss_secret"
            class="mt-2"
          >
            Done
          </.button>
        </div>

        <ul
          :if={@loaded? and @tokens != []}
          id="api-tokens"
          class="mb-4 divide-y divide-base-300 rounded-box border border-base-300 bg-base-200"
        >
          <li :for={t <- @tokens} id={"api-token-#{t.id}"} class="flex items-center gap-3 p-3">
            <.icon name="hero-key" class="size-5 opacity-50" />
            <div class="flex-1 min-w-0">
              <div class="truncate">{t.name}</div>
              <div class="text-xs opacity-60">
                …{t.hint} · {token_access(t)} · {token_usage(t)}<span :if={
                  t.created_by_id != @current_scope.user.id
                }> · {t.created_by.email}</span>
              </div>
            </div>
            <.button
              type="button"
              variant="ghost"
              size="xs"
              phx-click="revoke_token"
              phx-value-id={t.id}
              data-confirm={"Revoke “#{t.name}”? Anything using it stops working."}
            >
              Revoke
            </.button>
          </li>
        </ul>

        <.form
          for={@token_form}
          id="api-token-form"
          phx-submit="create_token"
          class="space-y-3"
        >
          <.input
            field={@token_form[:name]}
            placeholder="What will use it? e.g. Home Assistant"
            autocomplete="off"
          />
          <.input field={@token_form[:role]} type="select" options={token_role_options(@role)} />
          <.input
            field={@token_form[:expires_in_days]}
            type="select"
            options={[
              {"Never expires", ""}
              | Enum.map(ApiTokens.expiry_choices(), &{"Expires in #{&1} days", &1})
            ]}
          />
          <.button variant="primary" phx-disable-with="Creating…" class="w-full">
            Create token
          </.button>
        </.form>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Trygg.Accounts.subscribe_user(socket.assigns.current_scope.user.id)

    {:ok,
     socket
     |> assign(:form, to_form(Families.change_invite()))
     |> assign(:token_form, token_form())
     |> assign(:new_secret, nil)
     |> assign(:tokens, [])
     |> assign_owner()
     |> Loading.init()
     |> load()}
  end

  @impl true
  def handle_async(:load, result, socket),
    do: {:noreply, Loading.done(socket, result, &apply_people/2)}

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
  def handle_event("retry_load", _params, socket), do: {:noreply, load(socket)}

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

  def handle_event("create_token", %{"token" => params}, socket) do
    scope = socket.assigns.current_scope

    case ApiTokens.create_token(scope, socket.assigns.current_child.family_id, params) do
      {:ok, token} ->
        {:noreply,
         socket
         |> assign(:new_secret, %{name: token.name, secret: token.secret})
         |> assign(:token_form, token_form())
         |> load()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :token_form, to_form(changeset, as: :token))}
    end
  end

  def handle_event("dismiss_secret", _params, socket),
    do: {:noreply, assign(socket, :new_secret, nil)}

  def handle_event("revoke_token", %{"id" => id}, socket) do
    token = Enum.find(socket.assigns.tokens, &(&1.id == String.to_integer(id)))

    socket =
      if token do
        {:ok, _} = ApiTokens.revoke_token(socket.assigns.current_scope, token)
        put_flash(socket, :info, "“#{token.name}” revoked.")
      else
        socket
      end

    {:noreply, load(socket)}
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

  # The first load goes through `TryggWeb.Loading` (skeleton, then a task);
  # after that, membership changes reload in place. The invite form doesn't
  # depend on the list, so it's usable from the first paint.
  defp load(socket) do
    socket = assign_owner(socket)
    scope = socket.assigns.current_scope
    child = socket.assigns.current_child
    is_owner = socket.assigns.is_owner
    fetch = fn -> fetch_people(scope, child, is_owner) end

    if socket.assigns.loaded?,
      do: apply_people(socket, fetch.()),
      else: Loading.run(socket, fetch, &apply_people/2)
  end

  defp assign_owner(socket),
    do: assign(socket, :is_owner, socket.assigns.current_child.role == :owner)

  defp fetch_people(scope, child, is_owner) do
    %{
      members: Families.list_members(scope, child),
      invites: if(is_owner, do: Families.list_invites(scope, child), else: []),
      tokens: ApiTokens.list_tokens(scope, child.family_id)
    }
  end

  defp apply_people(socket, %{members: members, invites: invites, tokens: tokens}),
    do: assign(socket, members: members, invites: invites, tokens: tokens)

  defp token_form, do: to_form(ApiTokens.change_token(), as: :token)

  # A caregiver can't hand out more access than they have themselves.
  defp token_role_options(:viewer), do: [{"Read only", :viewer}]
  defp token_role_options(_role), do: [{"Read and log", :caregiver}, {"Read only", :viewer}]

  defp token_access(%{role: :viewer}), do: "read only"
  defp token_access(%{role: :caregiver}), do: "read and log"

  defp token_usage(%{last_used_at: nil}), do: "never used"
  defp token_usage(%{last_used_at: at}), do: "used #{relative_time(at)}"
end
