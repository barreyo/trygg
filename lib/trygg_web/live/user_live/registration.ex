defmodule TryggWeb.UserLive.Registration do
  use TryggWeb, :live_view

  alias Trygg.Accounts
  alias Trygg.Accounts.User
  alias Trygg.RateLimit
  alias TryggWeb.RequestIp

  import TryggWeb.LoginComponents, only: [login_sky: 1, login_hero: 1]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} immersive>
      <div id="register-stage" class="login-stage relative isolate mx-auto max-w-sm space-y-5">
        <.login_sky />

        <p class="login-rise text-center text-xs font-semibold uppercase tracking-[0.35em] text-white/80">
          Trygg
        </p>

        <.login_hero variant={:night} />

        <div class="login-rise login-copy text-center" style="--d: 0.15s">
          <h1 class="text-2xl font-bold text-white drop-shadow">Register for an account</h1>
          <p class="mt-2 text-sm text-white/80 [text-shadow:0_1px_10px_rgb(18_14_61_/_0.9)]">
            Already registered?
            <.link
              navigate={~p"/users/log-in"}
              id="register-login-link"
              class="font-semibold text-amber-200 underline underline-offset-4"
            >
              Log in
            </.link>
            to your account now.
          </p>
        </div>

        <div
          class="login-rise rounded-box bg-base-100/95 p-4 shadow-lg shadow-black/30 backdrop-blur-md"
          style="--d: 0.25s"
        >
          <.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
            <.input
              field={@form[:first_name]}
              type="text"
              label="First name"
              autocomplete="given-name"
              required
            />
            <.input
              field={@form[:last_name]}
              type="text"
              label="Last name"
              autocomplete="family-name"
              required
            />
            <.input
              field={@form[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              spellcheck="false"
              required
            />

            <.button
              variant="primary"
              phx-disable-with="Creating account..."
              class="login-cta mt-2 w-full"
            >
              Create an account <span class="login-cta-arrow" aria-hidden="true">→</span>
            </.button>
          </.form>
        </div>

        <p
          class="login-rise login-copy text-center text-sm text-white/75 [text-shadow:0_1px_10px_rgb(18_14_61_/_0.9)]"
          style="--d: 0.35s"
        >
          No password to remember. We'll email you a code to get in.
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: TryggWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_registration(%User{})

    {:ok, assign_form(assign(socket, :client_ip, RequestIp.from_socket(socket)), changeset),
     temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    ip = socket.assigns.client_ip

    with :ok <- RateLimit.check(:register_ip, ip),
         {:ok, user} <- Accounts.register_user(user_params) do
      {:ok, _} =
        Accounts.deliver_login_instructions(
          user,
          &url(~p"/users/log-in/#{&1}")
        )

      {:noreply,
       socket
       |> put_flash(
         :info,
         "An email was sent to #{user.email}, please access it to confirm your account."
       )
       |> put_flash(:email, user.email)
       |> push_navigate(to: ~p"/users/log-in")}
    else
      {:error, :rate_limited} ->
        {:noreply,
         put_flash(socket, :error, "Too many attempts. Please wait a few minutes and try again.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_registration(%User{}, user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
