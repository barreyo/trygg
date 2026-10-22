defmodule TryggWeb.ClimateBarTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.FamiliesFixtures

  alias Trygg.Devices

  setup %{conn: conn} do
    %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
    child = child_fixture(scope)
    %{conn: conn, scope: scope, child: child}
  end

  defp report(scope, child, attrs, hardware_id \\ "AA:BB") do
    {:ok, %{device: device}} =
      Devices.record_reading(scope, child.family_id, hardware_id, attrs)

    device
  end

  # The bar is updated with `send_update`, one message behind the page: two round trips to
  # the LiveView process get the mailbox past the broadcast and the update it queued.
  defp shown?(lv, selector, text \\ nil) do
    :sys.get_state(lv.pid)
    :sys.get_state(lv.pid)
    has_element?(lv, selector, text)
  end

  defp air(iaq, accuracy \\ 3),
    do: %{"temperature_c" => 21.4, "iaq" => iaq, "iaq_accuracy" => accuracy}

  test "there is no bar without a sensor", %{conn: conn, child: child} do
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}")
    refute shown?(lv, "#climate-bar-link")
  end

  test "an online sensor paints the bar by its air and shows the temperature", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    device = report(scope, child, air(30))
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}")

    assert shown?(lv, "#climate-bar-link[data-air=green]")
    assert shown?(lv, "#climate-bar-temperature", "21.4 °C")
    assert shown?(lv, ~s(#climate-bar-link[href="/c/#{child.id}/devices/#{device.id}"]))
  end

  test "the bar follows the air quality bands live", %{conn: conn, scope: scope, child: child} do
    report(scope, child, air(30))
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}")

    for {iaq, colour} <- [{120, "yellow"}, {180, "orange"}, {300, "red"}, {60, "green"}] do
      report(scope, child, air(iaq))
      assert shown?(lv, "#climate-bar-link[data-air=#{colour}]")
    end
  end

  test "the bar shows on other child pages too", %{conn: conn, scope: scope, child: child} do
    report(scope, child, air(180))

    for path <- [~p"/c/#{child}/vitals", ~p"/c/#{child}/devices", ~p"/c/#{child}/log"] do
      {:ok, lv, _html} = live(conn, path)
      assert shown?(lv, "#climate-bar-link[data-air=orange]")
    end
  end

  test "a sensor that is still calibrating, or has no index, gets a neutral bar", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    report(scope, child, air(30, 0))
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}")
    assert shown?(lv, "#climate-bar-link[data-air=unknown]", "21.4 °C")

    report(scope, child, %{"temperature_c" => 19.0, "gas_ohms" => 90_000.0})
    assert shown?(lv, "#climate-bar-link[data-air=unknown]", "19.0 °C")
  end

  test "the temperature follows the user's unit system", %{conn: conn, scope: scope, child: child} do
    {:ok, _} = Trygg.Accounts.update_user_settings(scope.user, %{unit_system: :imperial})
    report(scope, child, air(30))
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}")

    assert shown?(lv, "#climate-bar-temperature", "70.5 °F")
  end

  test "a first reading brings the bar up on an open page", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")
    refute shown?(lv, "#climate-bar-link")

    report(scope, child, air(30))
    assert shown?(lv, "#climate-bar-link[data-air=green]")
  end

  test "a sensor that has gone quiet drops off", %{conn: conn, scope: scope, child: child} do
    device = report(scope, child, air(30))
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}")
    assert shown?(lv, "#climate-bar-link")

    # Stands in for time passing: the next message about the device says it was last seen long ago.
    stale = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:second)
    {:ok, _} = Devices.name_device(scope, %{device | last_seen_at: stale}, %{name: "Nursery"})
    refute shown?(lv, "#climate-bar-link")
  end

  test "the periodic tick keeps the bar and the page up", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    report(scope, child, air(30))
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}")

    send(lv.pid, :climate_tick)
    assert shown?(lv, "#climate-bar-link[data-air=green]")
  end

  test "forgetting the sensor removes the bar", %{conn: conn, scope: scope, child: child} do
    device = report(scope, child, air(30))
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}")
    assert shown?(lv, "#climate-bar-link")

    {:ok, _} = Devices.delete_device(scope, device)
    refute shown?(lv, "#climate-bar-link")
  end

  test "with several sensors online the oldest one is shown", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    report(scope, child, air(30), "AA:01")
    report(scope, child, Map.put(air(300), "temperature_c", 25.0), "AA:02")
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}")

    assert shown?(lv, "#climate-bar-link[data-air=green]", "21.4 °C")
    report(scope, child, air(300), "AA:02")
    assert shown?(lv, "#climate-bar-link[data-air=green]", "21.4 °C")
  end

  test "pages that use the device messages still get them", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/devices")
    device = report(scope, child, air(30))

    assert shown?(lv, "#devices-#{device.id}-temperature", "21.4 °C")
    assert shown?(lv, "#climate-bar-link[data-air=green]")
  end
end
