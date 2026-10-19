defmodule Trygg.Devices.AirBaselineTest do
  use Trygg.DataCase, async: true

  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.Devices
  alias Trygg.Devices.{AirBaseline, Reading}

  @usual 100_000.0

  setup do
    scope = user_scope_fixture()
    child = child_fixture(scope)

    {:ok, %{device: device}} =
      Devices.record_reading(scope, child.family_id, "dev", %{"temperature_c" => 20})

    %{device: device, now: DateTime.utc_now()}
  end

  # One reading every 4 minutes over the last `days` days (up to 20 minutes ago), at `ohms`.
  defp history(device, now, days, ohms) do
    from = DateTime.add(now, round(-days * 86_400), :second)
    until = DateTime.add(now, -20 * 60, :second)

    from
    |> Stream.iterate(&DateTime.add(&1, 240, :second))
    |> Enum.take_while(&(DateTime.compare(&1, until) == :lt))
    |> Enum.map(&row(device, &1, ohms))
    |> Enum.chunk_every(1_000)
    |> Enum.each(&Repo.insert_all(Reading, &1))
  end

  defp recent(device, now, ohms) do
    rows = for minutes <- 1..5, do: row(device, DateTime.add(now, -minutes * 60, :second), ohms)
    Repo.insert_all(Reading, rows)
  end

  defp row(device, at, ohms) do
    %{
      device_id: device.id,
      measured_at: at,
      gas_ohms: ohms,
      inserted_at: DateTime.truncate(at, :second)
    }
  end

  test "alerts when the air has dropped well below the room's usual level", ctx do
    history(ctx.device, ctx.now, 3, @usual)
    recent(ctx.device, ctx.now, 55_000.0)

    assert %{percent_below: 45, usual_ohms: @usual, current_ohms: 55_000.0} =
             AirBaseline.alert(ctx.device.id, ctx.now)
  end

  test "stays quiet while the air is within its usual range", ctx do
    history(ctx.device, ctx.now, 3, @usual)
    recent(ctx.device, ctx.now, 80_000.0)

    assert AirBaseline.alert(ctx.device.id, ctx.now) == nil
  end

  test "stays quiet when the air is better than usual", ctx do
    history(ctx.device, ctx.now, 3, @usual)
    recent(ctx.device, ctx.now, 300_000.0)

    assert AirBaseline.alert(ctx.device.id, ctx.now) == nil
  end

  test "stays quiet until a day of history exists", ctx do
    history(ctx.device, ctx.now, 0.5, @usual)
    recent(ctx.device, ctx.now, 20_000.0)

    assert AirBaseline.alert(ctx.device.id, ctx.now) == nil
  end

  test "one noisy sample is not a change", ctx do
    history(ctx.device, ctx.now, 3, @usual)
    Repo.insert_all(Reading, [row(ctx.device, DateTime.add(ctx.now, -60, :second), 10_000.0)])

    assert AirBaseline.alert(ctx.device.id, ctx.now) == nil
  end

  test "a device without gas readings has nothing to compare", ctx do
    assert AirBaseline.alert(ctx.device.id, ctx.now) == nil
  end
end
