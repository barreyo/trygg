defmodule Trygg.Accounts.UserNotifier do
  alias Trygg.Accounts.User
  alias Trygg.Mailer
  alias Trygg.Mailer.Emails

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    Mailer.deliver_content(user.email, Emails.update_email(%{email: user.email, url: url}))
  end

  @doc """
  Deliver instructions to log in with a magic link, plus a short code for the
  installed app where the link can't be opened directly.
  """
  def deliver_login_instructions(user, url, code) do
    assigns = %{email: user.email, url: url, code: code}

    content =
      case user do
        %User{confirmed_at: nil} -> Emails.confirm_account(assigns)
        _ -> Emails.login_code(assigns)
      end

    Mailer.deliver_content(user.email, content)
  end
end
