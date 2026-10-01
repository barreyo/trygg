defmodule TryggWeb.InviteLive do
  use TryggWeb, :live_view

  alias Trygg.Families
  alias Trygg.Families.Family

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} title="Invitation" back={~p"/"}>
      <div class="text-center py-10">
        <%= case @state do %>
          <% {:ok, invite} -> %>
            <.icon name="hero-user-plus" class="size-12 mx-auto text-primary" />
            <h1 class="text-2xl font-semibold mt-4">Help track {Family.label(invite.family)}</h1>
            <p class="opacity-70 mt-2">
              {inviter_email(invite)} invited you as a <span class="font-medium">{invite.role}</span>.
            </p>
            <.button
              variant="primary"
              phx-click="accept"
              phx-disable-with="Joining…"
              class="mt-8 px-8"
            >
              Accept invitation
            </.button>
          <% {:error, :email_mismatch, invite} -> %>
            <.icon name="hero-exclamation-triangle" class="size-12 mx-auto text-warning" />
            <h1 class="text-xl font-semibold mt-4">Wrong account</h1>
            <p class="opacity-70 mt-2">
              This invitation was sent to <span class="font-medium">{invite.email}</span>,
              but you're signed in as {@current_scope.user.email}.
            </p>
            <.button variant="outline" href={~p"/users/log-out"} method="delete" class="mt-6">
              Log out and switch account
            </.button>
          <% :not_found -> %>
            <.icon name="hero-x-circle" class="size-12 mx-auto opacity-40" />
            <h1 class="text-xl font-semibold mt-4">Invitation not found</h1>
            <p class="opacity-70 mt-2">It may have been revoked or already used, or it expired.</p>
            <.button variant="outline" navigate={~p"/"} class="mt-6">Go home</.button>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    scope = socket.assigns.current_scope

    state =
      case Families.get_pending_invite(token) do
        nil ->
          :not_found

        invite ->
          if String.downcase(scope.user.email) == invite.email do
            {:ok, invite}
          else
            {:error, :email_mismatch, invite}
          end
      end

    {:ok, assign(socket, state: state, token: token)}
  end

  @impl true
  def handle_event("accept", _params, socket) do
    case Families.accept_invite(socket.assigns.current_scope, socket.assigns.token) do
      {:ok, child} ->
        {:noreply,
         socket
         |> put_flash(:info, "You're all set — now helping with #{child.name}.")
         |> push_navigate(to: ~p"/c/#{child}")}

      {:error, :email_mismatch} ->
        {:noreply,
         assign(socket, :state, {:error, :email_mismatch, socket.assigns.state |> elem(1)})}

      {:error, _} ->
        {:noreply, assign(socket, :state, :not_found)}
    end
  end

  defp inviter_email(%{invited_by: %{email: email}}), do: email
  defp inviter_email(_), do: "A caregiver"
end
