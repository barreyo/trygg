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
