defmodule Trygg.Growth.VelocityTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Growth.Measurement
  alias Trygg.Growth.Percentiles
  alias Trygg.Growth.Velocity

  @dob ~D[2026-01-01]

  defp child(attrs \\ %{}) do
    struct!(%Child{timezone: "Etc/UTC", birth_date: @dob, sex: :female}, attrs)
  end

  defp measurement(id, %Date{} = date, grams) do
    %Measurement{
      id: id,
      measured_at: DateTime.new!(date, ~T[00:00:00], "Etc/UTC"),
      weight_g: grams
    }
  end

  test "needs two weights at least five days apart" do
    assert %{available?: false, latest: nil} = Velocity.summarize(child(), [])

    one = [measurement(1, ~D[2026-02-01], 4000.0)]
    assert %{available?: false, latest: %{grams: 4000.0}} = Velocity.summarize(child(), one)

    close = [measurement(1, ~D[2026-02-01], 4000.0), measurement(2, ~D[2026-02-03], 4100.0)]
    refute Velocity.summarize(child(), close).available?
  end

  test "prefers a prior reading one to five weeks back and reports g/day" do
    measurements = [
      measurement(1, ~D[2026-02-01], 4000.0),
      measurement(2, ~D[2026-02-24], 4600.0),
      measurement(3, ~D[2026-02-27], 4650.0),
      measurement(4, ~D[2026-03-01], 4700.0)
    ]

    summary = Velocity.summarize(child(), measurements)
    assert summary.available?
    assert summary.prior.date == ~D[2026-02-01]
    assert summary.velocity.days == 28
    assert summary.velocity.gain_g == 700.0
    assert_in_delta summary.velocity.g_per_day, 25.0, 0.01
    assert_in_delta summary.velocity.g_per_week, 175.0, 0.01
    assert summary.velocity.guide_g_per_day == {20, 30}
    assert summary.velocity.guide_status == :within
  end

  test "computes percentile movement and the hold-percentile expected gain" do
    # Sit exactly on the CDC 50th at both dates → Δz ≈ 0, expected ≈ actual.
    p50_start = Percentiles.value_at(child(), :weight, 50, ~D[2026-02-01])
    p50_end = Percentiles.value_at(child(), :weight, 50, ~D[2026-03-01])

    measurements = [
      measurement(1, ~D[2026-02-01], p50_start),
      measurement(2, ~D[2026-03-01], p50_end)
    ]

    v = Velocity.summarize(child(), measurements).velocity
    assert_in_delta v.z_prev, 0.0, 0.01
    assert_in_delta v.delta_z, 0.0, 0.02
    assert_in_delta v.expected_gain_g, v.gain_g, 5.0
    assert v.percentile_now in 49..51
    refute v.percentile_drop?
  end

  test "flags a drop across a major centile band over two weeks or more" do
    p50 = Percentiles.value_at(child(), :weight, 50, ~D[2026-02-01])
    p15 = Percentiles.value_at(child(), :weight, 15, ~D[2026-03-01])

    v =
      Velocity.summarize(child(), [
        measurement(1, ~D[2026-02-01], p50),
        measurement(2, ~D[2026-03-01], p15)
      ]).velocity

    assert v.delta_z < -0.67
    assert v.percentile_drop?
  end

  test "without percentiles the age guide still applies" do
    v =
      Velocity.summarize(child(%{sex: :unspecified}), [
        measurement(1, ~D[2026-02-01], 4000.0),
        measurement(2, ~D[2026-02-15], 4140.0)
      ]).velocity

    assert v.z_now == nil
    assert v.expected_gain_g == nil
    assert v.guide_status == :below
  end

  test "newborn loss and regain use the birth-date measurement" do
    measurements = [
      measurement(1, @dob, 3500.0),
      measurement(2, ~D[2026-01-04], 3100.0),
      measurement(3, ~D[2026-01-12], 3520.0)
    ]

    newborn = Velocity.summarize(child(), measurements).newborn
    assert newborn.birth_grams == 3500.0
    assert_in_delta newborn.loss_pct, 11.43, 0.01
    assert newborn.loss_flag?
    assert newborn.regained_day == 11
    assert newborn.regained_by_14?
    refute newborn.regain_overdue?
  end

  test "regain is overdue once a reading after day 14 is still below birth weight" do
    newborn =
      Velocity.summarize(child(), [
        measurement(1, @dob, 3500.0),
        measurement(2, ~D[2026-01-18], 3400.0)
      ]).newborn

    assert newborn.regain_overdue?
    refute newborn.loss_flag?
    assert_in_delta newborn.latest_pct_of_birth, 97.14, 0.01
  end

  test "newborn checks stop after two months and prompt for a birth weight before that" do
    old = [measurement(1, @dob, 3500.0), measurement(2, ~D[2026-04-01], 6000.0)]
    assert Velocity.summarize(child(), old).newborn == nil

    # prompt_birth_weight? depends on the child's age today, so use a fresh birth date
    fresh = child(%{birth_date: Date.add(Date.utc_today(), -10)})
    assert Velocity.summarize(fresh, []).prompt_birth_weight?

    with_birth = [measurement(1, fresh.birth_date, 3500.0)]
    refute Velocity.summarize(fresh, with_birth).prompt_birth_weight?
  end

  test "a preterm child turning two doesn't slide for the switch to chronological age" do
    # Born at 28+0 weeks, so corrected age runs 12 weeks behind until age two.
    baby = child(sex: :male, gestational_age_days: 196)
    before_two = ~D[2027-12-10]
    after_two = ~D[2028-01-10]

    # Tracking the corrected-age median exactly across the birthday.
    on_track = fn date -> Percentiles.value_at_z(baby, :weight, 0.0, date, corrected: true) end

    measurements = [
      measurement(1, before_two, on_track.(before_two)),
      measurement(2, after_two, on_track.(after_two))
    ]

    # Scored on mixed bases this would look like a percentile slide.
    mixed =
      Percentiles.zscore(baby, :weight, on_track.(after_two), after_two) -
        Percentiles.zscore(baby, :weight, on_track.(before_two), before_two)

    assert mixed < -0.25

    %{velocity: velocity} = Velocity.summarize(baby, measurements)
    assert_in_delta velocity.delta_z, 0.0, 0.1
    refute velocity.percentile_drop?
  end
end
