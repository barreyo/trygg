defmodule TryggWeb.UserLive.Login do
  use TryggWeb, :live_view

  alias Trygg.Accounts
  alias Trygg.Accounts.UserToken
  alias Trygg.RateLimit
  alias TryggWeb.RequestIp

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <%= if @sent_to do %>
          <div class="text-center">
            <.header>
              <p>Check your email</p>
              <:subtitle>
                Tap the link in the email we sent to <span class="font-medium">{@sent_to}</span>, or enter the {@code_digits}-digit
                code from it here.
              </:subtitle>
            </.header>
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

          <p class="text-center text-sm opacity-70">
            Didn't get it?
            <button
              type="button"
              id="login_start_over"
              phx-click="start_over"
              class="font-semibold text-brand hover:underline cursor-pointer"
            >
              Send a new one
            </button>
          </p>
        <% else %>
          <div class="text-center">
            <.header>
              <p>Log in</p>
              <:subtitle>
                <%= if @current_scope do %>
                  You need to reauthenticate to perform sensitive actions on your account.
                <% else %>
                  We'll email you a login link — no password to remember. Don't have an account? <.link
                    navigate={~p"/users/register"}
                    class="font-semibold text-brand hover:underline"
                    phx-no-format
                  >Sign up</.link> first.
                <% end %>
              </:subtitle>
            </.header>
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
              label="Email"
              autocomplete="username"
              spellcheck="false"
              required
              phx-mounted={JS.focus()}
            />
            <.button variant="primary" class="w-full">
              Email me a login link <span aria-hidden="true">→</span>
            </.button>
          </.form>
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

  def handle_event("start_over", _params, socket) do
    form = to_form(%{"email" => socket.assigns.sent_to}, as: "user", id: "login_form_magic")
    {:noreply, assign(socket, sent_to: nil, form: form)}
  end

  defp local_mail_adapter? do
    Application.get_env(:trygg, Trygg.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
