defmodule TryggWeb.UserSessionControllerTest do
  use TryggWeb.ConnCase, async: true

  import Trygg.AccountsFixtures
  alias Trygg.Accounts

  setup do
    %{unconfirmed_user: unconfirmed_user_fixture(), user: user_fixture()}
  end

  describe "POST /users/log-in - magic link" do
    test "logs the user in", %{conn: conn, user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token}
        })

      assert get_session(conn, :user_token)
      assert conn.resp_cookies["_trygg_web_user_remember_me"]
      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request and assert the app renders for the user
      conn = get(conn, ~p"/children")
      response = html_response(conn, 200)
      assert response =~ "Children"
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log-out"
    end

    test "sets a persistent session cookie so iOS keeps it when the app is killed", %{
      conn: conn,
      user: user
    } do
      {token, _hashed_token} = generate_user_magic_link_token(user)

      conn = post(conn, ~p"/users/log-in", %{"user" => %{"token" => token}})

      assert %{max_age: max_age} = conn.resp_cookies["_trygg_key"]
      assert max_age == 365 * 24 * 60 * 60
    end

    test "logs the user in with return to", %{conn: conn, user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)

      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> post(~p"/users/log-in", %{"user" => %{"token" => token}})

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "confirms unconfirmed user", %{conn: conn, unconfirmed_user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)
      refute user.confirmed_at

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token},
          "_action" => "confirmed"
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "User confirmed successfully."

      assert Accounts.get_user!(user.id).confirmed_at

      # Now do a logged in request and assert the app renders for the user
      conn = get(conn, ~p"/children")
      response = html_response(conn, 200)
      assert response =~ "Children"
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log-out"
    end

    test "redirects to login page when magic link is invalid", %{conn: conn} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => "invalid"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "The link is invalid or it has expired."

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "POST /users/log-in - login code" do
    test "logs the user in", %{conn: conn, user: user} do
      code = extract_login_code(user)

      conn =
        post(conn, ~p"/users/log-in", %{"user" => %{"email" => user.email, "code" => code}})

      assert get_session(conn, :user_token)
      assert conn.resp_cookies["_trygg_web_user_remember_me"]
      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "logged in"
    end

    test "confirms an unconfirmed user", %{conn: conn, unconfirmed_user: user} do
      code = extract_login_code(user)

      conn =
        post(conn, ~p"/users/log-in", %{"user" => %{"email" => user.email, "code" => code}})

      assert get_session(conn, :user_token)
      assert Accounts.get_user!(user.id).confirmed_at
    end

    test "sends the user back to the code step when the code is wrong", %{
      conn: conn,
      user: user
    } do
      _code = extract_login_code(user)

      conn =
        post(conn, ~p"/users/log-in", %{"user" => %{"email" => user.email, "code" => "000000"}})

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid or has expired"
      assert Phoenix.Flash.get(conn.assigns.flash, :email) == user.email
    end
  end

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end
end
