defmodule Trygg.Growth.PretermStandardTest do
  use ExUnit.Case, async: true

  alias Trygg.Growth.PretermStandard

  @fixtures Path.expand("../../support/fixtures/intergrowth", __DIR__)
  @centiles %{
    "p3" => 3,
    "p5" => 5,
    "p10" => 10,
    "p50" => 50,
    "p90" => 90,
    "p95" => 95,
    "p97" => 97
  }

  defp parse_int_rows(path) do
    [header | lines] = path |> File.read!() |> String.split("\n", trim: true)
    keys = String.split(header, ",")

    Enum.map(lines, fn line ->
      [week | vals] = String.split(line, ",")

      Map.new(Enum.zip(tl(keys), Enum.map(vals, &String.to_float/1)))
      |> Map.put("pma_weeks", String.to_integer(week))
    end)
  end

  test "reproduces the published z-score table at every exact week" do
    path = Path.expand("../../../priv/intergrowth/preterm_weight_boys_zscores.csv", __DIR__)

    for row <- parse_int_rows(path),
        {key, z} <- [{"sd_m2", -2.0}, {"sd_0", 0.0}, {"sd_1", 1.0}, {"sd_3", 3.0}] do
      days = row["pma_weeks"] * 7
      assert_in_delta PretermStandard.zscore(:male, :weight, days, row[key]), z, 1.0e-9
      assert_in_delta PretermStandard.value_at_z(:male, :weight, days, z), row[key], 1.0e-9
    end
  end

  test "agrees with the published centile tables to within their rounding" do
    for {kind, sex, name} <- [
          {:weight, :male, "boys"},
          {:weight, :female, "girls"},
          {:length, :male, "boys"},
          {:length, :female, "girls"}
        ],
        row <- parse_int_rows(Path.join(@fixtures, "preterm_#{kind}_#{name}_centiles.csv")),
        {key, centile} <- @centiles do
      z = PretermStandard.zscore(sex, kind, row["pma_weeks"] * 7, row[key])
      pct = 50.0 * (1.0 + :math.erf(z / :math.sqrt(2.0)))

      assert abs(pct - centile) < 2.0,
             "#{kind} #{name} week #{row["pma_weeks"]} #{key}: got #{Float.round(pct, 2)}"
    end
  end

  test "interpolates between weeks" do
    # Boys' weight medians: 32 weeks 1.60 kg, 33 weeks 1.81 kg.
    mid = PretermStandard.value_at_z(:male, :weight, 32 * 7 + 3, 0.0)
    assert mid > 1.60 and mid < 1.81
    assert_in_delta mid, 1.60 + (1.81 - 1.60) * 3 / 7, 0.005
  end

  test "extrapolates past ±3 SD and is nil outside 27–64 weeks" do
    assert PretermStandard.zscore(:female, :weight, 40 * 7, 1.5) < -3.0
    assert PretermStandard.zscore(:female, :weight, 40 * 7, 6.0) > 3.0
    assert PretermStandard.zscore(:male, :weight, 27 * 7 - 1, 1.0) == nil
    assert PretermStandard.zscore(:male, :weight, 64 * 7 + 1, 7.0) == nil
    assert PretermStandard.value_at_z(:male, :length, 26 * 7, 0.0) == nil
    assert PretermStandard.range_days() == 189..448
  end
end
