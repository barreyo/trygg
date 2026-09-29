defmodule TryggWeb.GrowthComponentsTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Growth.Measurement
  alias TryggWeb.GrowthComponents

  defp measurement(id, date, grams) do
    %Measurement{
      id: id,
      measured_at: DateTime.new!(date, ~T[12:00:00], "Etc/UTC"),
      weight_g: grams
    }
  end

  test "the y-axis never drops below zero across a preemie's wide range" do
    dob = ~D[2026-01-01]
    child = %Child{sex: :female, birth_date: dob, timezone: "Etc/UTC", gestational_age_days: 224}
    measurements = [measurement(2, Date.add(dob, 240), 7100.0), measurement(1, dob, 1500.0)]
    to = Date.add(dob, 240)

    chart =
      GrowthComponents.build_chart(measurements, :weight_g, :weight, :metric, child, dob, to)

    assert chart.show_bands
    assert chart.band_label == "INTERGROWTH-21st → CDC"
    assert chart.handover
    assert Enum.all?(chart.y_ticks, &(&1.label >= 0))
    assert hd(chart.y_ticks).label == 0
  end
end
