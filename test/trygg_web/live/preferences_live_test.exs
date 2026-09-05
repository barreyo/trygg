defmodule TryggWeb.PreferencesLiveTest do
  use TryggWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Trygg.Accounts

  setup :register_and_log_in_user

  describe "measurement units" do
    test "saving switches the stored unit system", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/preferences")

      lv
      |> form("#preferences-form", user: %{unit_system: "imperial"})
      |> render_change()

      assert Accounts.get_user!(user.id).unit_system == :imperial
    end
  end

  describe "theme" do
    test "renders a theme option per choice", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/preferences")

      assert html =~ ~s(name="user[theme]" value="system")
      assert html =~ ~s(name="user[theme]" value="light")
      assert html =~ ~s(name="user[theme]" value="dark")
    end

    test "defaults to system, checked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/preferences")

      assert lv |> element(~s(input[name="user[theme]"][value="system"])) |> render() =~ "checked"
    end

    test "saving persists the chosen theme and pushes it to the client", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/preferences")

      render_change(form(lv, "#preferences-form", user: %{theme: "dark"}))

      assert_push_event(lv, "set-theme", %{theme: "dark"})
      assert Accounts.get_user!(user.id).theme == :dark
    end

    test "saving system clears any prior override", %{conn: conn, user: user} do
      {:ok, _} = Accounts.update_user_settings(user, %{theme: :dark})

      {:ok, lv, _html} = live(conn, ~p"/preferences")

      render_change(form(lv, "#preferences-form", user: %{theme: "system"}))

      assert_push_event(lv, "set-theme", %{theme: "system"})
      assert Accounts.get_user!(user.id).theme == :system
    end
  end

  describe "root layout" do
    test "signed-in user's explicit theme is rendered on <html>", %{conn: conn, user: user} do
      {:ok, _} = Accounts.update_user_settings(user, %{theme: :dark})

      assert get(conn, ~p"/preferences") |> html_response(200) =~ ~s(data-user-theme="dark")
    end
  end
end
