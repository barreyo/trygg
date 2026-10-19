defmodule Trygg.DevicesTest do
  use Trygg.DataCase, async: true

  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.{ApiTokens, Devices}
  alias Trygg.Devices.Device

  setup do
    scope = user_scope_fixture()
    child = child_fixture(scope)
    %{scope: scope, child: child, family_id: child.family_id}
  end

  @sample %{
    "temperature_c" => 21.5,
    "humidity_pct" => 45.2,
    "pressure_hpa" => 1013.2,
    "gas_ohms" => 120_000.0
  }

  describe "record_reading/4" do
    test "registers an unnamed device on the first reading, then reuses it", ctx do
      assert {:ok, %{device: device, reading: reading}} =
               Devices.record_reading(ctx.scope, ctx.family_id, "AA:BB:CC:DD:EE:FF", @sample)

      assert device.name == nil
      assert device.hardware_id == "AA:BB:CC:DD:EE:FF"
      assert device.latest == reading
      assert reading.temperature_c == 21.5

      assert {:ok, %{device: again}} =
               Devices.record_reading(ctx.scope, ctx.family_id, "AA:BB:CC:DD:EE:FF", @sample)

      assert again.id == device.id
      assert [%Device{latest: %{id: id}}] = Devices.list_devices(ctx.scope, ctx.family_id)
      assert id != reading.id
    end

    test "broadcasts the reading to the family's topic", ctx do
      Devices.subscribe(ctx.family_id)

      {:ok, %{device: device}} =
        Devices.record_reading(ctx.scope, ctx.family_id, "dev-1", @sample)

      assert_receive {:device_reading, %Device{id: id}, %{temperature_c: 21.5}}
      assert id == device.id
    end

    test "keeps devices apart per family" do
      a = user_scope_fixture()
      b = user_scope_fixture()
      child_a = child_fixture(a)
      child_b = child_fixture(b)

      {:ok, %{device: da}} = Devices.record_reading(a, child_a.family_id, "same", @sample)
      {:ok, %{device: db}} = Devices.record_reading(b, child_b.family_id, "same", @sample)

      assert da.id != db.id
      assert Devices.list_devices(a, child_a.family_id) |> Enum.map(& &1.id) == [da.id]
    end

    test "rejects out-of-range values, empty readings and bad hardware ids", ctx do
      assert {:error, cs} =
               Devices.record_reading(ctx.scope, ctx.family_id, "dev", %{"temperature_c" => 400})

      assert %{temperature_c: [_]} = errors_on(cs)

      assert {:error, _} = Devices.record_reading(ctx.scope, ctx.family_id, "dev", %{})

      assert {:error, cs} =
               Devices.record_reading(ctx.scope, ctx.family_id, "bad id/../", @sample)

      assert %{hardware_id: [_]} = errors_on(cs)
      assert Devices.list_devices(ctx.scope, ctx.family_id) == []
    end

    test "stores BSEC's air quality alongside the raw readings", ctx do
      air = %{"iaq" => 48.5, "iaq_accuracy" => 3, "co2_ppm" => 620.0, "voc_ppm" => 0.6}

      assert {:ok, %{reading: reading}} =
               Devices.record_reading(
                 ctx.scope,
                 ctx.family_id,
                 "dev",
                 Map.merge(@sample, air)
               )

      assert %{iaq: 48.5, iaq_accuracy: 3, co2_ppm: 620.0, voc_ppm: 0.6} = reading
    end

    test "rejects an air quality index outside BSEC's scale", ctx do
      assert {:error, cs} =
               Devices.record_reading(ctx.scope, ctx.family_id, "dev", %{
                 "iaq" => 501,
                 "iaq_accuracy" => 4
               })

      assert %{iaq: [_], iaq_accuracy: [_]} = errors_on(cs)
    end

    test "viewers can't report", ctx do
      {:ok, token} = ApiTokens.create_token(ctx.scope, ctx.family_id, %{name: "t", role: :viewer})
      {:ok, viewer_scope} = ApiTokens.authenticate(token.secret)

      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        Devices.record_reading(viewer_scope, ctx.family_id, "dev", @sample)
      end
    end
  end

  describe "name_device/3 and delete_device/2" do
    setup ctx do
      {:ok, %{device: device}} = Devices.record_reading(ctx.scope, ctx.family_id, "dev", @sample)
      %{device: device}
    end

    test "names a device and announces it", ctx do
      Devices.subscribe(ctx.family_id)
      assert {:ok, device} = Devices.name_device(ctx.scope, ctx.device, %{"name" => "  Nursery "})
      assert device.name == "Nursery"
      assert device.latest == ctx.device.latest
      assert_receive {:device_changed, %Device{name: "Nursery"}}
    end

    test "needs a name", ctx do
      assert {:error, cs} = Devices.name_device(ctx.scope, ctx.device, %{"name" => " "})
      assert %{name: [_]} = errors_on(cs)
    end

    test "forgets a device with its readings, and it registers again", ctx do
      Devices.subscribe(ctx.family_id)
      assert {:ok, _} = Devices.delete_device(ctx.scope, ctx.device)
      assert_receive {:device_deleted, id}
      assert id == ctx.device.id
      assert Devices.list_devices(ctx.scope, ctx.family_id) == []

      {:ok, %{device: new}} = Devices.record_reading(ctx.scope, ctx.family_id, "dev", @sample)
      assert new.id != ctx.device.id
      assert new.name == nil
    end

    test "viewers can look but not rename", ctx do
      viewer = user_fixture()
      membership_fixture(ctx.child, viewer, :viewer)
      viewer_scope = user_scope_fixture(viewer)

      assert [_] = Devices.list_devices(viewer_scope, ctx.family_id)

      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        Devices.name_device(viewer_scope, ctx.device, %{"name" => "x"})
      end
    end
  end

  describe "short ids" do
    test "a registered device gets a five-digit id that stays put", ctx do
      {:ok, %{device: device}} =
        Devices.record_reading(ctx.scope, ctx.family_id, "dev", @sample)

      assert device.short_id in 10_000..99_999

      {:ok, %{device: again}} =
        Devices.record_reading(ctx.scope, ctx.family_id, "dev", @sample)

      assert again.short_id == device.short_id
      assert Device.label(device) == "New device #{device.short_id}"
    end

    test "are unique within a family", ctx do
      ids =
        for n <- 1..30 do
          {:ok, %{device: device}} =
            Devices.record_reading(ctx.scope, ctx.family_id, "dev-#{n}", @sample)

          device.short_id
        end

      assert length(Enum.uniq(ids)) == 30
    end

    test "registration draws another id when one is taken" do
      taken = 12_345

      # Only one id is ever free in this stubbed range, so the retry has to find it.
      scope = user_scope_fixture()
      child = child_fixture(scope)

      Trygg.Repo.insert!(%Device{
        family_id: child.family_id,
        hardware_id: "first",
        short_id: taken
      })

      for n <- 1..5 do
        {:ok, %{device: device}} =
          Devices.record_reading(scope, child.family_id, "other-#{n}", @sample)

        assert device.short_id != taken
      end
    end
  end

  describe "set_on_today/3 and set_today_devices/3" do
    setup ctx do
      {:ok, %{device: a}} = Devices.record_reading(ctx.scope, ctx.family_id, "a", @sample)
      {:ok, %{device: b}} = Devices.record_reading(ctx.scope, ctx.family_id, "b", @sample)
      %{a: a, b: b}
    end

    test "devices start off the Today screen", ctx do
      refute ctx.a.on_today
    end

    test "pins one device and broadcasts it", ctx do
      Devices.subscribe(ctx.family_id)

      assert {:ok, %Device{on_today: true}} = Devices.set_on_today(ctx.scope, ctx.a, true)
      assert_receive {:device_changed, %Device{id: id, on_today: true}}
      assert id == ctx.a.id
      assert Devices.get_device!(ctx.scope, ctx.family_id, ctx.a.id).on_today
    end

    test "pins exactly the given devices and reports what changed", ctx do
      assert [%Device{id: id}] = Devices.set_today_devices(ctx.scope, ctx.family_id, [ctx.b.id])
      assert id == ctx.b.id

      assert [] = Devices.set_today_devices(ctx.scope, ctx.family_id, [to_string(ctx.b.id)])

      assert [%Device{id: a_id, on_today: true}, %Device{id: b_id, on_today: false}] =
               Devices.set_today_devices(ctx.scope, ctx.family_id, [ctx.a.id])

      assert {a_id, b_id} == {ctx.a.id, ctx.b.id}
    end

    test "viewers can't pin", ctx do
      viewer = user_fixture()
      membership_fixture(ctx.child, viewer, :viewer)
      viewer_scope = user_scope_fixture(viewer)

      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        Devices.set_on_today(viewer_scope, ctx.a, true)
      end
    end
  end

  describe "history/3" do
    defp report_at(ctx, minutes_ago, temperature) do
      at = DateTime.utc_now() |> DateTime.add(-minutes_ago * 60) |> DateTime.to_iso8601()

      {:ok, %{device: device}} =
        Devices.record_reading(
          ctx.scope,
          ctx.family_id,
          "dev",
          Map.merge(@sample, %{"temperature_c" => temperature, "measured_at" => at})
        )

      device
    end

    test "averages readings into time buckets, oldest first, and skips older ones", ctx do
      report_at(ctx, 300, 10.0)
      report_at(ctx, 120, 20.0)
      device = report_at(ctx, 119, 22.0)
      report_at(ctx, 5, 18.0)

      %{points: points, bucket: bucket, from: from, to: to} =
        Devices.history(ctx.scope, device, 3 * 3600)

      assert bucket == 90
      assert DateTime.diff(to, from) == 3 * 3600
      # The 5 h old one is outside the window; the two close ones share a bucket
      # or sit in neighbouring ones, but never come back out of order.
      assert length(points) in 2..3
      assert points == Enum.sort_by(points, & &1.at, DateTime)
      assert %{temperature_c: 18.0} = List.last(points)
      assert Enum.all?(points, &(&1.humidity_pct == 45.2))
    end

    test "viewers can look, other families' scopes can't", ctx do
      device = report_at(ctx, 1, 20.0)
      assert %{points: [_]} = Devices.history(ctx.scope, device, 3600)

      stranger = user_scope_fixture()

      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        Devices.history(stranger, device, 3600)
      end
    end
  end

  test "prune_readings/1 drops only old readings", ctx do
    {:ok, %{device: device}} = Devices.record_reading(ctx.scope, ctx.family_id, "dev", @sample)
    old = DateTime.add(DateTime.utc_now(), -40, :day) |> DateTime.to_iso8601()

    {:ok, _} =
      Devices.record_reading(
        ctx.scope,
        ctx.family_id,
        "dev",
        Map.put(@sample, "measured_at", old)
      )

    assert Devices.prune_readings(30) == 1
    assert Devices.get_device!(ctx.scope, ctx.family_id, device.id).latest
  end
end
