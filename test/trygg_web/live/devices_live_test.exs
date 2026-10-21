defmodule TryggWeb.DevicesLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.Devices

  @sample %{"temperature_c" => 21.5, "humidity_pct" => 45.0, "pressure_hpa" => 1012.0}

  setup %{conn: conn} do
    %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
    child = child_fixture(scope)
    %{conn: conn, scope: scope, child: child}
  end

  test "shows an empty state with no devices", %{conn: conn, child: child} do
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/devices")
    assert has_element?(lv, "#devices-empty")
  end

  test "a new device appears live with its readings and can be named", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/devices")

    {:ok, %{device: device}} = Devices.record_reading(scope, child.family_id, "AA:BB", @sample)

    assert has_element?(lv, "#devices-#{device.id}-temperature", "21.5 °C")
    assert has_element?(lv, "#devices-#{device.id}-humidity", "45 %")
    assert has_element?(lv, "#devices-#{device.id}-status", "Live")

    lv
    |> form("#devices-#{device.id}-form", device: %{name: "Nursery"})
    |> render_submit()

    assert render(lv) =~ "Nursery"
    assert Devices.get_device!(scope, child.family_id, device.id).name == "Nursery"
  end

  test "shows the device's five-digit id and lets a member pin it to their own Today", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    {:ok, %{device: device}} = Devices.record_reading(scope, child.family_id, "AA:BB", @sample)
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/devices")

    assert has_element?(lv, "#devices-#{device.id}-short-id", to_string(device.short_id))
    refute has_element?(lv, "#devices-#{device.id}-today-toggle[checked]")

    lv |> element("#devices-#{device.id}-today-toggle") |> render_click()

    assert MapSet.member?(Devices.pinned_ids(scope, child.family_id), device.id)
    assert has_element?(lv, "#devices-#{device.id}-today-toggle[checked]")

    lv |> element("#devices-#{device.id}-today-toggle") |> render_click()

    assert Devices.pinned_ids(scope, child.family_id) == MapSet.new()
    refute has_element?(lv, "#devices-#{device.id}-today-toggle[checked]")
  end

  test "another member's pin doesn't tick the box, and a viewer can pin for themself", %{
    scope: scope,
    child: child
  } do
    {:ok, %{device: device}} = Devices.record_reading(scope, child.family_id, "AA:BB", @sample)
    {:ok, _} = Devices.set_on_today(scope, device, true)

    viewer = user_fixture()
    membership_fixture(child, viewer, :viewer)
    {:ok, lv, _html} = live(log_in_user(build_conn(), viewer), ~p"/c/#{child}/devices")

    refute has_element?(lv, "#devices-#{device.id}-today-toggle[checked]")
    lv |> element("#devices-#{device.id}-today-toggle") |> render_click()
    assert has_element?(lv, "#devices-#{device.id}-today-toggle[checked]")
  end

  test "a newer sample replaces the value on screen", %{conn: conn, scope: scope, child: child} do
    {:ok, %{device: device}} = Devices.record_reading(scope, child.family_id, "AA:BB", @sample)
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/devices")
    assert has_element?(lv, "#devices-#{device.id}-temperature", "21.5")

    {:ok, _} =
      Devices.record_reading(scope, child.family_id, "AA:BB", %{@sample | "temperature_c" => 23.0})

    assert has_element?(lv, "#devices-#{device.id}-temperature", "23.0")
  end

  test "a named device can be forgotten", %{conn: conn, scope: scope, child: child} do
    {:ok, %{device: device}} = Devices.record_reading(scope, child.family_id, "AA:BB", @sample)
    {:ok, _} = Devices.name_device(scope, device, %{"name" => "Kitchen"})
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/devices")

    render_click(lv, "delete_device", %{"id" => to_string(device.id)})

    refute has_element?(lv, "#devices-#{device.id}")
    assert Devices.list_devices(scope, child.family_id) == []
  end

  test "viewers see readings but no naming form", %{conn: conn, scope: scope, child: child} do
    {:ok, %{device: device}} = Devices.record_reading(scope, child.family_id, "AA:BB", @sample)
    viewer = user_fixture()
    membership_fixture(child, viewer, :viewer)

    {:ok, lv, _html} = live(log_in_user(build_conn(), viewer), ~p"/c/#{child}/devices")

    assert has_element?(lv, "#devices-#{device.id}-temperature")
    refute has_element?(lv, "#devices-#{device.id}-form")
    _ = conn
  end
end
