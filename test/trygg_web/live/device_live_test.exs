defmodule TryggWeb.DeviceLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.Devices

  @sample %{
    "temperature_c" => 21.5,
    "humidity_pct" => 45.0,
    "pressure_hpa" => 1012.0,
    "gas_ohms" => 120_000.0
  }

  setup %{conn: conn} do
    %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
    child = child_fixture(scope)
    {:ok, %{device: device}} = Devices.record_reading(scope, child.family_id, "AA:BB", @sample)
    %{conn: conn, scope: scope, child: child, device: device}
  end

  defp ago(minutes),
    do: DateTime.utc_now() |> DateTime.add(-minutes * 60) |> DateTime.to_iso8601()

  defp report(ctx, minutes_ago, temperature) do
    {:ok, _} =
      Devices.record_reading(
        ctx.scope,
        ctx.child.family_id,
        "AA:BB",
        %{
          @sample
          | "temperature_c" => temperature
        }
        |> Map.put("measured_at", ago(minutes_ago))
      )
  end

  test "shows the current values and a graph per measurement", ctx do
    report(ctx, 30, 19.0)
    {:ok, lv, _html} = live(ctx.conn, ~p"/c/#{ctx.child}/devices/#{ctx.device.id}")

    assert has_element?(lv, "#device-short-id", to_string(ctx.device.short_id))
    assert has_element?(lv, "#today-device-#{ctx.device.id}-temperature", "21.5 °C")

    for id <- ~w(temperature humidity pressure air) do
      assert has_element?(lv, "#device-chart-#{id}-plot svg polyline")
      assert has_element?(lv, "#device-chart-#{id}-readout")
    end

    # Embedded for the scrubbing hook: [x, y, when, value] per point.
    assert render(lv) =~ "21.5 °C"
  end

  describe "air quality" do
    test "a unit without BSEC doesn't get its graphs or notes", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/c/#{ctx.child}/devices/#{ctx.device.id}")

      refute has_element?(lv, "#device-chart-iaq")
      refute has_element?(lv, "#device-chart-co2")
      refute has_element?(lv, "#device-air-calibrating")
      refute has_element?(lv, "#device-air-alert")
    end

    test "a unit running BSEC graphs the index and CO₂ equivalent, and says while it is learning",
         ctx do
      {:ok, _} =
        Devices.record_reading(
          ctx.scope,
          ctx.child.family_id,
          "AA:BB",
          Map.merge(@sample, %{
            "iaq" => 62.0,
            "iaq_accuracy" => 2,
            "co2_ppm" => 640.0
          })
        )

      {:ok, lv, _html} = live(ctx.conn, ~p"/c/#{ctx.child}/devices/#{ctx.device.id}")

      assert has_element?(
               lv,
               "#device-chart-iaq-plot svg polyline, #device-chart-iaq-plot svg circle"
             )

      assert has_element?(lv, "#device-chart-co2-readout")

      # Tinted regions behind the index, for the bands the data and the axis cover.
      assert has_element?(lv, "#device-chart-iaq-plot [data-band='Excellent']")
      assert has_element?(lv, "#device-chart-iaq-plot [data-band='Good']")
      refute has_element?(lv, "#device-chart-iaq-plot [data-band='Poor']")
      assert render(lv) =~ "62 IAQ · Good"
      assert has_element?(lv, "#device-air-calibrating")

      {:ok, _} =
        Devices.record_reading(
          ctx.scope,
          ctx.child.family_id,
          "AA:BB",
          Map.merge(@sample, %{"iaq" => 55.0, "iaq_accuracy" => 3})
        )

      refute has_element?(lv, "#device-air-calibrating")
      assert has_element?(lv, "#today-device-#{ctx.device.id}-gas", "Good")
    end

    test "explains the alert when the air is below its usual level, even if the device isn't pinned",
         ctx do
      now = DateTime.utc_now()

      rows =
        for i <- 1..1_200 do
          at = DateTime.add(now, -(20 + i * 4) * 60, :second)

          %{
            device_id: ctx.device.id,
            measured_at: at,
            gas_ohms: 100_000.0,
            inserted_at: DateTime.truncate(at, :second)
          }
        end

      rows
      |> Enum.chunk_every(500)
      |> Enum.each(&Trygg.Repo.insert_all(Trygg.Devices.Reading, &1))

      {:ok, lv, _html} = live(ctx.conn, ~p"/c/#{ctx.child}/devices/#{ctx.device.id}")
      refute has_element?(lv, "#device-air-alert")

      for _ <- 1..3 do
        {:ok, _} =
          Devices.record_reading(ctx.scope, ctx.child.family_id, "AA:BB", %{
            @sample
            | "gas_ohms" => 50_000.0
          })
      end

      assert has_element?(lv, "#device-air-alert", "50 % below usual")
      assert has_element?(lv, "#device-air-alert", "100 kΩ")
    end
  end

  test "switching the range patches the page and keeps the current values", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/c/#{ctx.child}/devices/#{ctx.device.id}")
    assert has_element?(lv, "#device-range-24h[aria-current]")

    lv |> element("#device-range-7d") |> render_click()

    assert_patch(lv, ~p"/c/#{ctx.child}/devices/#{ctx.device.id}?range=7d")
    assert has_element?(lv, "#device-range-7d[aria-current]")
    refute has_element?(lv, "#device-range-24h[aria-current]")
    assert has_element?(lv, "#device-chart-temperature-plot")
  end

  test "an unknown range falls back to 24 hours", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/c/#{ctx.child}/devices/#{ctx.device.id}?range=bogus")
    assert has_element?(lv, "#device-range-24h[aria-current]")
  end

  test "a new reading updates the values and the graph live", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/c/#{ctx.child}/devices/#{ctx.device.id}")
    refute render(lv) =~ "27.0 °C"

    {:ok, _} =
      Devices.record_reading(ctx.scope, ctx.child.family_id, "AA:BB", %{
        @sample
        | "temperature_c" => 27.0
      })

    assert has_element?(lv, "#today-device-#{ctx.device.id}-temperature", "27.0 °C")
    assert render(lv) =~ "27.0 °C"
  end

  test "a period with no readings says so", ctx do
    {:ok, other} =
      Devices.record_reading(ctx.scope, ctx.child.family_id, "CC:DD", %{
        "temperature_c" => 20.0,
        "measured_at" => ago(60 * 24 * 3)
      })

    {:ok, lv, _html} = live(ctx.conn, ~p"/c/#{ctx.child}/devices/#{other.device.id}?range=6h")

    assert has_element?(lv, "#device-chart-humidity-empty")
    assert has_element?(lv, "#device-chart-temperature-empty")
  end

  test "the unit system applies to the temperature graph", ctx do
    scope = ctx.scope
    {:ok, _} = Trygg.Accounts.update_user_settings(scope.user, %{unit_system: :imperial})
    {:ok, lv, _html} = live(ctx.conn, ~p"/c/#{ctx.child}/devices/#{ctx.device.id}")
    assert render(lv) =~ "70.7 °F"
  end

  test "an unknown or foreign device goes back to the list", ctx do
    {:error, {:live_redirect, %{to: path}}} =
      live(ctx.conn, ~p"/c/#{ctx.child}/devices/0")

    assert path == ~p"/c/#{ctx.child}/devices"

    other = user_scope_fixture()
    other_child = child_fixture(other)

    {:ok, %{device: foreign}} =
      Devices.record_reading(other, other_child.family_id, "XX", @sample)

    {:error, {:live_redirect, %{to: ^path}}} =
      live(ctx.conn, ~p"/c/#{ctx.child}/devices/#{foreign.id}")
  end

  test "is linked from the Devices page and from the Today card", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/c/#{ctx.child}/devices")
    assert has_element?(lv, "#devices-#{ctx.device.id}-open")

    {:ok, _} = Devices.set_on_today(ctx.scope, ctx.device, true)
    {:ok, lv, _html} = live_loaded(ctx.conn, ~p"/c/#{ctx.child}")

    lv |> element("#today-device-#{ctx.device.id}-open") |> render_click()
    assert_redirect(lv, ~p"/c/#{ctx.child}/devices/#{ctx.device.id}")
  end

  test "a forgotten device sends the page back to the list", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/c/#{ctx.child}/devices/#{ctx.device.id}")
    {:ok, _} = Devices.delete_device(ctx.scope, ctx.device)
    assert_redirect(lv, ~p"/c/#{ctx.child}/devices")
  end
end
