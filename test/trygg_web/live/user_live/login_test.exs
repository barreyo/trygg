defmodule TryggWeb.UserLive.LoginTest do
  use TryggWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Trygg.AccountsFixtures

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Email me a login link"
      refute has_element?(lv, "#app-menu")
    end

    test "shows the illustration on both steps", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      assert has_element?(lv, "#login-scene-night[phx-hook='LoginScene']")

      {:ok, lv, _html} =
        form(lv, "#login_form_magic", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert has_element?(lv, "#login-scene-mail")
      refute has_element?(lv, "#login-scene-night")
    end

    test "puts account creation ahead of the login form", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/log-in")

      assert has_element?(lv, "#login-new-here #login-register-link[href='/users/register']")
      assert has_element?(lv, "#login_form_magic")

      # The register card comes before the login form in the page.
      {register_at, _} = :binary.match(html, ~s(id="login-new-here"))
      {form_at, _} = :binary.match(html, ~s(id="login_form_magic"))
      assert register_at < form_at
    end
  end

  describe "user login - magic link" do
    test "sends magic link email when user exists", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is in our system"

      contexts =
        Trygg.Repo.all(Trygg.Accounts.UserToken)
        |> Enum.filter(&(&1.user_id == user.id))
        |> Enum.map(& &1.context)
        |> Enum.sort()

      assert contexts == ["login", "login_code"]
    end

    test "shows the code step after requesting a link", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, lv, html} =
        form(lv, "#login_form_magic", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ user.email
      assert has_element?(lv, "#login-no-account-hint")
      assert has_element?(lv, "#login_form_code")
      assert has_element?(lv, "#login_form_code input[name='user[email]'][value='#{user.email}']")
      refute has_element?(lv, "#login_form_magic")

      # Back to the email step, prefilled.
      lv |> element("#login_start_over") |> render_click()
      assert has_element?(lv, "#login_form_magic input[value='#{user.email}']")
      refute has_element?(lv, "#login_form_code")
    end

    test "restores the code step when the client resumes a pending login", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      # The page is carrying the hook that remembers/restores the pending login.
      assert has_element?(lv, "#login-resume[phx-hook='LoginResume']")
      refute has_element?(lv, "#login_form_code")

      render_hook(lv, "resume", %{"email" => user.email})

      assert has_element?(lv, "#login_form_code input[name='user[email]'][value='#{user.email}']")
      refute has_element?(lv, "#login_form_magic")
      assert has_element?(lv, "#login-resume[data-sent-to='#{user.email}']")
    end

    test "ignores a malformed resume request", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      render_hook(lv, "resume", %{"email" => "not-an-email"})
      render_hook(lv, "resume", %{"email" => String.duplicate("a", 300) <> "@example.com"})

      assert has_element?(lv, "#login_form_magic")
      refute has_element?(lv, "#login_form_code")
    end

    test "logs in with the emailed code", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, lv, _html} =
        form(lv, "#login_form_magic", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      # The LiveView submit only issued a link+code; grab the code the same way
      # a user would, from the latest email.
      code = extract_login_code(user)

      conn =
        conn
        |> recycle()
        |> post(~p"/users/log-in", %{"user" => %{"email" => user.email, "code" => code}})

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
      assert has_element?(lv, "#login_form_code")
    end

    test "returns to the code step after a wrong code", %{conn: conn} do
      user = user_fixture()

      conn =
        post(conn, ~p"/users/log-in", %{"user" => %{"email" => user.email, "code" => "000000"}})

      {:ok, lv, html} = live(recycle(conn), ~p"/users/log-in")
      assert html =~ "invalid or has expired"
      assert has_element?(lv, "#login_form_code")
    end

    test "does not disclose if user is registered", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", user: %{email: "idonotexist@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is in our system"
    end
  end

  describe "login navigation" do
    test "redirects to registration page when the Register button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _login_live, login_html} =
        lv
        |> element("#login-register-link")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/register")

      assert login_html =~ "Register"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows login page with email filled in", %{conn: conn, user: user} do
      {:ok, lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "You need to reauthenticate"
      refute html =~ "Register"
      refute has_element?(lv, "#login-new-here")
      assert html =~ "Email me a login link"

      assert html =~
               ~s(<input type="email" name="user[email]" id="login_form_magic_email" value="#{user.email}")
    end
  end
end
