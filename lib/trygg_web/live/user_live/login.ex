defmodule TryggWeb.UserLive.Login do
  use TryggWeb, :live_view

  alias Trygg.Accounts
  alias Trygg.Accounts.UserToken
  alias Trygg.RateLimit
  alias TryggWeb.RequestIp

  import TryggWeb.LoginComponents, only: [login_sky: 1, login_hero: 1]

  @impl true
  def render(assigns) do
    # Signed out we paint the full-screen night sky and the copy sits on it.
    # Re-authenticating while signed in keeps the normal app chrome (and its
    # way out of the page), so it gets the plain look.
    assigns = assign(assigns, :immersive, is_nil(assigns.current_scope))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} immersive={@immersive}>
      <div
        id="login-resume"
        phx-hook="LoginResume"
        data-sent-to={@sent_to}
        class="login-stage relative isolate mx-auto max-w-sm space-y-5"
      >
        <.login_sky :if={@immersive} />

        <p
          :if={@immersive}
          class="login-rise text-center text-xs font-semibold uppercase tracking-[0.35em] text-white/80"
        >
          Trygg
        </p>

        <%= if @sent_to do %>
          <.login_hero :if={@immersive} variant={:mail} />

          <div class="login-rise text-center" style="--d: 0.15s">
            <h1 class={["text-2xl font-bold", @immersive && "text-white drop-shadow"]}>
              Check your email
            </h1>
            <p class={[
              "mt-2 text-sm",
              if(@immersive,
                do: "text-white/80 [text-shadow:0_1px_10px_rgb(18_14_61_/_0.9)]",
                else: "opacity-70"
              )
            ]}>
              If <span class={["font-semibold", @immersive && "text-white"]}>{@sent_to}</span>
              has a Trygg account, we've just emailed it a link and a {@code_digits}-digit code. Tap the link, or enter the code here.
            </p>
          </div>

          <div :if={local_mail_adapter?()} class="alert alert-info">
            <.icon name="hero-information-circle" class="size-6 shrink-0" />
            <div>
              <p>You are running the local mail adapter.</p>
              <p>
                To see sent emails, visit <.link href="/dev/mailbox" class="underline">the mailbox page</.link>.
              </p>
            </div>
          </div>

          <div
            class={[
              "login-rise rounded-3xl p-4",
              @immersive && "bg-base-100/95 shadow-lg shadow-black/30 backdrop-blur-md"
            ]}
            style="--d: 0.25s"
          >
            <%!-- Plain POST (no phx-submit): the controller owns verification and
                 rate limiting so a direct request can't bypass either. --%>
            <.form for={@code_form} id="login_form_code" action={~p"/users/log-in"} method="post">
              <input type="hidden" name={@code_form[:email].name} value={@sent_to} />
              <.input
                field={@code_form[:code]}
                type="text"
                label="Login code"
                inputmode="numeric"
                autocomplete="one-time-code"
                pattern="[0-9 -]*"
                maxlength={@code_digits + 2}
                placeholder={String.duplicate("0", @code_digits)}
                spellcheck="false"
                required
                phx-mounted={JS.focus()}
              />
              <.button variant="primary" class="w-full">
                Log in with code <span aria-hidden="true">→</span>
              </.button>
            </.form>
          </div>

          <p
            class={[
              "login-rise text-center text-sm",
              if(@immersive,
                do: "text-white/75 [text-shadow:0_1px_10px_rgb(18_14_61_/_0.9)]",
                else: "opacity-70"
              )
            ]}
            style="--d: 0.35s"
          >
            Didn't get it?
            <button
              type="button"
              id="login_start_over"
              phx-click={
                JS.dispatch("trygg:login-clear", to: "#login-resume") |> JS.push("start_over")
              }
              class={[
                "cursor-pointer font-semibold hover:underline",
                if(@immersive, do: "text-amber-200", else: "text-brand")
              ]}
            >
              Send a new one
            </button>
          </p>

          <div
            :if={!@current_scope}
            id="login-no-account-hint"
            class="login-rise rounded-3xl border border-warning/50 bg-base-100/95 p-4 text-sm shadow-lg shadow-black/30 backdrop-blur-md"
            style="--d: 0.45s"
          >
            <p class="font-semibold">Nothing arrived?</p>
            <p class="mt-1 opacity-80">
              We only send login emails to accounts that already exist. If you haven't registered yet, create your account first — that email has your code.
            </p>
            <.button
              navigate={~p"/users/register"}
              id="login-no-account-register"
              variant="outline"
              size="sm"
              class="mt-3 w-full"
            >
              Create an account
            </.button>
          </div>
        <% else %>
          <.login_hero :if={@immersive} variant={:night} />

          <div class="login-rise text-center" style="--d: 0.15s">
            <h1 class={["text-2xl font-bold", @immersive && "text-white drop-shadow"]}>
              {if @current_scope, do: "Log in", else: "Welcome to Trygg"}
            </h1>
            <p class={[
              "mt-2 text-sm",
              if(@immersive,
                do: "text-white/80 [text-shadow:0_1px_10px_rgb(18_14_61_/_0.9)]",
                else: "opacity-70"
              )
            ]}>
              <%= if @current_scope do %>
                You need to reauthenticate to perform sensitive actions on your account.
              <% else %>
                New here? Create your account first. After that, logging in is just your email — no password.
              <% end %>
            </p>
          </div>

          <div
            :if={!@current_scope}
            id="login-new-here"
            class="login-rise login-new-card relative overflow-hidden rounded-3xl border border-primary/40 bg-base-100 bg-gradient-to-br from-primary/20 via-base-100 to-base-100 p-4 shadow-lg shadow-black/30"
            style="--d: 0.25s"
          >
            <div class="flex items-start gap-3">
              <span class="grid size-10 shrink-0 place-items-center rounded-full bg-primary text-primary-content shadow">
                <.icon name="hero-sparkles" class="size-5" />
              </span>
              <div>
                <p class="font-semibold">New to Trygg?</p>
                <p class="text-sm opacity-70">
                  Create your account first — it only takes a few seconds.
                </p>
              </div>
            </div>
            <.button
              navigate={~p"/users/register"}
              id="login-register-link"
              variant="primary"
              class="login-cta mt-4 w-full"
            >
              Create an account <span class="login-cta-arrow" aria-hidden="true">→</span>
            </.button>
          </div>

          <div :if={local_mail_adapter?()} class="alert alert-info">
            <.icon name="hero-information-circle" class="size-6 shrink-0" />
            <div>
              <p>You are running the local mail adapter.</p>
              <p>
                To see sent emails, visit <.link href="/dev/mailbox" class="underline">the mailbox page</.link>.
              </p>
            </div>
          </div>

          <div
            class={[
              "login-rise rounded-3xl p-4",
              @immersive && "bg-base-100/95 shadow-lg shadow-black/30 backdrop-blur-md"
            ]}
            style="--d: 0.4s"
          >
            <p :if={!@current_scope} class="mb-3 text-sm font-semibold">Already registered?</p>
            <.form
              for={@form}
              id="login_form_magic"
              action={~p"/users/log-in"}
              phx-submit="submit_magic"
            >
              <.input
                readonly={!!@current_scope}
                field={@form[:email]}
                type="email"
                label={if @current_scope, do: "Email", else: "Email of your existing account"}
                autocomplete="username"
                spellcheck="false"
                required
                phx-mounted={@current_scope && JS.focus()}
              />
              <.button variant={if @current_scope, do: "primary", else: "outline"} class="w-full">
                Email me a login link <span aria-hidden="true">→</span>
              </.button>
            </.form>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    # `:email` in the flash means a login email was just requested (here or
    # from registration), or a code attempt failed: either way show the code
    # step for that address.
    sent_to = Phoenix.Flash.get(socket.assigns.flash, :email)

    email =
      sent_to ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    {:ok,
     assign(socket,
       form: to_form(%{"email" => email}, as: "user", id: "login_form_magic"),
       code_form: to_form(%{"code" => ""}, as: "user", id: "login_form_code"),
       code_digits: UserToken.login_code_digits(),
       sent_to: sent_to,
       client_ip: RequestIp.from_socket(socket)
     )}
  end

  @impl true
  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    ip = socket.assigns.client_ip
    email = String.trim(email)
    email_key = String.downcase(email)

    with :ok <- RateLimit.check(:login_ip, ip),
         :ok <- RateLimit.check(:login_email, email_key),
         %{} = user <- Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))
    else
      _ -> :ok
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> put_flash(:email, email)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  # Sent by the LoginResume hook when the page comes back on the email step
  # but this browser has a recent, unfinished login (the flash that carried the
  # code step is short-lived and doesn't survive a reload). Only restores the
  # code form; the code itself is still verified by the session controller.
  def handle_event("resume", %{"email" => email}, %{assigns: %{sent_to: nil}} = socket)
      when is_binary(email) and byte_size(email) <= 254 do
    email = String.trim(email)

    if String.contains?(email, "@") do
      form = to_form(%{"email" => email}, as: "user", id: "login_form_magic")
      {:noreply, assign(socket, sent_to: email, form: form)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("resume", _params, socket), do: {:noreply, socket}

  def handle_event("start_over", _params, socket) do
    form = to_form(%{"email" => socket.assigns.sent_to}, as: "user", id: "login_form_magic")
    {:noreply, assign(socket, sent_to: nil, form: form)}
  end

  defp local_mail_adapter? do
    Application.get_env(:trygg, Trygg.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
