defmodule Trygg.Reports.NormsTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Reports.Norms

  test "age_days counts whole days from the birth date" do
    child = %Child{birth_date: ~D[2026-01-01], timezone: "Etc/UTC"}
    assert Norms.age_days(child, ~D[2026-01-11]) == 10
    assert Norms.age_days(child, ~D[2025-12-31]) == nil
    assert Norms.age_days(%Child{timezone: "Etc/UTC"}, ~D[2026-01-11]) == nil
  end

  test "corrected_age_days/2 uses corrected age for a preterm baby until two" do
    # Born at 32+0 weeks: term date is 2026-02-26.
    baby = %Child{timezone: "Etc/UTC", birth_date: ~D[2026-01-01], gestational_age_days: 224}

    assert Norms.corrected_age_days(baby, ~D[2026-01-11]) == 0
    assert Norms.corrected_age_days(baby, ~D[2026-03-08]) == 10
    assert Norms.corrected_age_days(baby, ~D[2027-12-31]) == 729 - 56
    # Chronological from the second birthday.
    assert Norms.corrected_age_days(baby, ~D[2028-01-01]) == 730

    term = %{baby | gestational_age_days: 275}
    assert Norms.corrected_age_days(term, ~D[2026-03-08]) == 66
    assert Norms.corrected_age_days(%{baby | birth_date: nil}, ~D[2026-03-08]) == nil
  end

  test "wake windows widen with age and stop after three years" do
    assert {2400, 3600} = Norms.wake_window_range(10)
    assert {lo, hi} = Norms.wake_window_range(120)
    assert lo < hi
    assert Norms.wake_window_range(2000) == nil
    assert Norms.wake_window_range(nil) == nil

    # Lower bound is non-decreasing with age.
    {lo_1mo, _} = Norms.wake_window_range(30)
    {lo_6mo, _} = Norms.wake_window_range(180)
    {lo_1yr, _} = Norms.wake_window_range(365)
    assert lo_1mo <= lo_6mo and lo_6mo <= lo_1yr

    # Interpolated, so no jump across a former band boundary.
    {lo_a, hi_a} = Norms.wake_window_range(89)
    {lo_b, hi_b} = Norms.wake_window_range(91)
    assert abs(lo_a - lo_b) < 3 * 60
    assert abs(hi_a - hi_b) < 3 * 60
  end

  test "typical_nap_count steps 4 → 3 → 2 → 1 across the first 15 months" do
    assert Norms.typical_nap_count(30) == 4
    assert Norms.typical_nap_count(120) == 3
    assert Norms.typical_nap_count(300) == 2
    assert Norms.typical_nap_count(500) == 1
    assert Norms.typical_nap_count(2000) == nil
    assert Norms.typical_nap_count(nil) == nil
  end

  test "wake_window_position_factor shortens the first window and lengthens the last" do
    assert Norms.wake_window_position_factor(1, 4) < 1.0
    assert Norms.wake_window_position_factor(4, 4) > 1.0
    assert Norms.wake_window_position_factor(1, 1) == 1.0
    # A middle window sits near 1.0.
    mid = Norms.wake_window_position_factor(2, 4)
    assert mid > 0.85 and mid < 1.15
  end

  test "intake guide narrows by age and ends after the first year" do
    assert {150, 180} = Norms.intake_ml_per_kg(30)
    assert {120, 150} = Norms.intake_ml_per_kg(120)
    assert {100, 120} = Norms.intake_ml_per_kg(300)
    assert Norms.intake_ml_per_kg(400) == nil
  end

  test "typical feeds follow the first-year formula table" do
    assert %{feeds_per_day: {8, 12}, ml_per_feed: {30, 60}} = Norms.typical_feeds(3)
    assert %{feeds_per_day: {6, 8}, ml_per_feed: {60, 120}} = Norms.typical_feeds(30)
    assert %{feeds_per_day: {5, 6}, ml_per_feed: {150, 180}} = Norms.typical_feeds(60)
    assert %{feeds_per_day: {5, 6}, ml_per_feed: {180, 210}} = Norms.typical_feeds(120)
    assert %{feeds_per_day: {5, 6}, ml_per_feed: nil} = Norms.typical_feeds(250)
    assert Norms.typical_feeds(400) == nil
    assert Norms.typical_feeds(nil) == nil
  end

  test "calories are estimated at 0.67 kcal per ml of bottle volume" do
    assert Norms.kcal_per_ml() == 0.67
    assert_in_delta Norms.estimated_kcal(600), 402.0, 0.01
    assert Norms.estimated_kcal(nil) == nil
    assert Norms.kcal_note() =~ "0.67 kcal/ml"
  end

  test "wet diaper floor ramps over the first five days of life" do
    assert Norms.min_wet_diapers(0) == 1
    assert Norms.min_wet_diapers(3) == 4
    assert Norms.min_wet_diapers(30) == 6
    assert Norms.min_wet_diapers(nil) == 6
  end

  test "expected weight gain is highest in the first months" do
    assert Norms.weight_gain_g_per_day(7) == nil
    assert {20, 30} = Norms.weight_gain_g_per_day(45)
    assert {8, 15} = Norms.weight_gain_g_per_day(300)
    assert Norms.weight_gain_g_per_day(400) == nil
  end
end
