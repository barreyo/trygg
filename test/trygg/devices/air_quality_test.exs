defmodule Trygg.Devices.AirQualityTest do
  use ExUnit.Case, async: true

  alias Trygg.Devices.AirQuality

  test "words for the index, a boundary belonging to the cleaner band" do
    assert AirQuality.label(0) == "Excellent"
    assert AirQuality.label(50) == "Excellent"
    assert AirQuality.label(50.1) == "Good"
    assert AirQuality.label(150) == "Fair"
    assert AirQuality.label(200) == "Poor"
    assert AirQuality.label(250) == "Bad"
    assert AirQuality.label(420) == "Very bad"
  end

  test "the bands run unbroken from 0 to 500" do
    bands = AirQuality.bands()
    assert hd(bands).from == 0
    assert List.last(bands).to == 500
    assert Enum.chunk_every(bands, 2, 1, :discard) |> Enum.all?(fn [a, b] -> a.to == b.from end)
  end

  test "level collapses the bands into the four status bar colours" do
    assert for(
             iaq <- [0, 50, 51, 100, 101, 150, 151, 200, 201, 250, 400],
             do: AirQuality.level(iaq)
           ) ==
             [
               :green,
               :green,
               :green,
               :green,
               :yellow,
               :yellow,
               :orange,
               :orange,
               :red,
               :red,
               :red
             ]
  end
end
