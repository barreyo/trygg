defmodule TryggWeb.PreferencesLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Trygg.Accounts

  setup :register_and_log_in_user

  test "shows the weight-check reminder options, recommended by default", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/preferences")

    assert has_element?(lv, "#reminder-options")
    assert has_element?(lv, "input[name='user[weight_reminder_days]'][value='7']")
    assert has_element?(lv, "input[name='user[weight_reminder_days]'][value='0']")
    assert has_element?(lv, "input[name='user[weight_reminder_days]'][value=''][checked]")
  end

  test "picking a cadence persists it", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, ~p"/preferences")

    lv
    |> form("#preferences-form", user: %{weight_reminder_days: "14"})
    |> render_change()

    assert Accounts.get_user!(scope.user.id).weight_reminder_days == 14
    assert has_element?(lv, "input[name='user[weight_reminder_days]'][value='14'][checked]")
  end

  test "choosing Recommended clears a previously set cadence", %{conn: conn, scope: scope} do
    {:ok, _} = Accounts.update_user_settings(scope.user, %{"weight_reminder_days" => 7})

    {:ok, lv, _html} = live(conn, ~p"/preferences")

    lv
    |> form("#preferences-form", user: %{weight_reminder_days: ""})
    |> render_change()

    assert Accounts.get_user!(scope.user.id).weight_reminder_days == nil
  end

  test "rejects an out-of-range cadence", %{scope: scope} do
    assert {:error, %Ecto.Changeset{}} =
             Accounts.update_user_settings(scope.user, %{"weight_reminder_days" => 9999})

    assert Accounts.get_user!(scope.user.id).weight_reminder_days == nil
  end
end
