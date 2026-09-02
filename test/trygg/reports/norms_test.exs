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

  test "wake windows widen with age and stop after three years" do
    assert {2700, 3600} = Norms.wake_window_range(10)
    assert {lo, hi} = Norms.wake_window_range(120)
    assert lo < hi
    assert Norms.wake_window_range(2000) == nil
    assert Norms.wake_window_range(nil) == nil
  end

  test "intake guide narrows by age and ends after the first year" do
    assert {150, 180} = Norms.intake_ml_per_kg(30)
    assert {120, 150} = Norms.intake_ml_per_kg(120)
    assert {100, 120} = Norms.intake_ml_per_kg(300)
    assert Norms.intake_ml_per_kg(400) == nil
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
