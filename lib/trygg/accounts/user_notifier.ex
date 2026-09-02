defmodule Trygg.Accounts.UserNotifier do
  import Swoosh.Email

  alias Trygg.Mailer
  alias Trygg.Accounts.User

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(Mailer.from_address())
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link, plus a short code for the
  installed app where the link can't be opened directly.
  """
  def deliver_login_instructions(user, url, code) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url, code)
      _ -> deliver_magic_link_instructions(user, url, code)
    end
  end

  defp deliver_magic_link_instructions(user, url, code) do
    deliver(user.email, "Your Trygg login code is #{code}", """

    ==============================

    Hi #{user.email},

    Your login code is:

    #{code}

    Enter it in the Trygg app, or log in directly by visiting the URL below:

    #{url}

    The code and link expire in 15 minutes and can only be used once.

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url, code) do
    deliver(user.email, "Confirm your Trygg account — code #{code}", """

    ==============================

    Hi #{user.email},

    Your confirmation code is:

    #{code}

    Enter it in the Trygg app, or confirm your account by visiting the URL below:

    #{url}

    The code and link expire in 15 minutes and can only be used once.

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end
end
