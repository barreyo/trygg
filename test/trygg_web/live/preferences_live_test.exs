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

    test "the form carries the client hook that applies the theme without a reload", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/preferences")

      assert lv |> element("#preferences-form") |> render() =~ ~s(phx-hook="Theme")
    end

    test "saving persists the chosen theme", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/preferences")

      render_change(form(lv, "#preferences-form", user: %{theme: "dark"}))

      assert Accounts.get_user!(user.id).theme == :dark
    end

    test "saving system clears any prior override", %{conn: conn, user: user} do
      {:ok, _} = Accounts.update_user_settings(user, %{theme: :dark})

      {:ok, lv, _html} = live(conn, ~p"/preferences")

      render_change(form(lv, "#preferences-form", user: %{theme: "system"}))

      assert Accounts.get_user!(user.id).theme == :system
    end
  end

  describe "notifications" do
    test "renders the push opt-in widget wired to the hook and VAPID key", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/preferences")

      assert html =~ ~s(id="push-notifications")
      assert html =~ ~s(phx-hook="PushNotifications")
      # The dev/test VAPID public key is handed to the client for subscribe().
      assert html =~ "data-vapid-key=\"#{Trygg.Push.vapid_public_key()}\""
      assert html =~ ~s(data-push-action="enable")
    end
  end

  describe "root layout" do
    test "signed-in user's explicit theme is rendered on <html>", %{conn: conn, user: user} do
      {:ok, _} = Accounts.update_user_settings(user, %{theme: :dark})

      assert get(conn, ~p"/preferences") |> html_response(200) =~ ~s(data-user-theme="dark")
    end
  end

  describe "weight-check reminders" do
    test "shows the cadence options, recommended by default", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/preferences")

      assert has_element?(lv, "#reminder-options")
      assert has_element?(lv, "input[name='user[weight_reminder_days]'][value='7']")
      assert has_element?(lv, "input[name='user[weight_reminder_days]'][value='0']")
      assert has_element?(lv, "input[name='user[weight_reminder_days]'][value=''][checked]")
    end

    test "picking a cadence persists it", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/preferences")

      lv
      |> form("#preferences-form", user: %{weight_reminder_days: "14"})
      |> render_change()

      assert Accounts.get_user!(user.id).weight_reminder_days == 14
      assert has_element?(lv, "input[name='user[weight_reminder_days]'][value='14'][checked]")
    end

    test "choosing Recommended clears a previously set cadence", %{conn: conn, user: user} do
      {:ok, _} = Accounts.update_user_settings(user, %{"weight_reminder_days" => 7})

      {:ok, lv, _html} = live(conn, ~p"/preferences")

      lv
      |> form("#preferences-form", user: %{weight_reminder_days: ""})
      |> render_change()

      assert Accounts.get_user!(user.id).weight_reminder_days == nil
    end

    test "rejects an out-of-range cadence", %{user: user} do
      assert {:error, %Ecto.Changeset{}} =
               Accounts.update_user_settings(user, %{"weight_reminder_days" => 9999})

      assert Accounts.get_user!(user.id).weight_reminder_days == nil
    end
  end
end
