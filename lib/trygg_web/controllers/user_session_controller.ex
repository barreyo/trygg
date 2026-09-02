defmodule TryggWeb.UserSessionController do
  use TryggWeb, :controller

  alias Trygg.Accounts
  alias Trygg.RateLimit
  alias TryggWeb.UserAuth

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "User confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # login code typed in (the installed-app path; see UserToken.build_login_code/1).
  # Verification happens here, not in the LiveView, so a direct POST can't
  # sidestep the per-email attempt limit. Failures bounce back to the code step
  # by carrying the email in the flash, which is what the login page keys on.
  defp create(conn, %{"user" => %{"email" => email, "code" => code} = user_params}, _info) do
    email_key = email |> String.trim() |> String.downcase()

    with :ok <- RateLimit.check(:login_code, email_key),
         {:ok, {user, tokens_to_disconnect}} <- Accounts.login_user_by_code(email, code) do
      UserAuth.disconnect_sessions(tokens_to_disconnect)

      conn
      |> put_flash(:info, "You're logged in.")
      |> UserAuth.log_in_user(user, user_params)
    else
      {:error, :rate_limited} ->
        conn
        |> put_flash(
          :error,
          "Too many attempts. Request a new code and try again in a few minutes."
        )
        |> redirect(to: ~p"/users/log-in")

      _ ->
        conn
        |> put_flash(:error, "That code is invalid or has expired.")
        |> put_flash(:email, email)
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
