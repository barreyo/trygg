defmodule Trygg.UnitsTest do
  use ExUnit.Case, async: true

  alias Trygg.Units

  describe "unit_label/2" do
    test "metric and imperial labels" do
      assert Units.unit_label(:volume, :metric) == "ml"
      assert Units.unit_label(:volume, :imperial) == "oz"
      assert Units.unit_label(:weight, :metric) == "kg"
      assert Units.unit_label(:weight, :imperial) == "lb"
      assert Units.unit_label(:length, :metric) == "cm"
      assert Units.unit_label(:length, :imperial) == "in"
    end
  end

  describe "weight" do
    test "metric display is kilograms, storage is grams" do
      assert Units.to_display(3200, :weight, :metric) == 3.2
      assert Units.from_display(3.2, :weight, :metric) == 3200.0
      assert Units.format(3200, :weight, :metric) == "3.2 kg"
      assert Units.format(3000, :weight, :metric) == "3 kg"
    end

    test "imperial display is pounds" do
      assert Units.to_display(4535.9237, :weight, :imperial) == 10.0
      assert Units.from_display(10, :weight, :imperial) == 4535.9237
      assert Units.format(4535.9237, :weight, :imperial) == "10 lb"
    end

    test "nil passes through" do
      assert Units.to_display(nil, :weight, :metric) == nil
      assert Units.from_display(nil, :weight, :imperial) == nil
      assert Units.format(nil, :weight, :metric) == nil
    end
  end

  describe "length" do
    test "metric is centimetres (identity)" do
      assert Units.to_display(50.8, :length, :metric) == 50.8
      assert Units.from_display(50.8, :length, :metric) == 50.8
      assert Units.format(50, :length, :metric) == "50 cm"
    end

    test "imperial is inches" do
      assert Units.to_display(50.8, :length, :imperial) == 20.0
      assert Units.from_display(20, :length, :imperial) == 50.8
      assert Units.format(50.8, :length, :imperial) == "20 in"
    end
  end

  describe "volume" do
    test "metric millilitres are unchanged" do
      assert Units.to_display(90, :volume, :metric) == 90.0
      assert Units.from_display(90, :volume, :metric) == 90.0
      assert Units.format(90, :volume, :metric) == "90 ml"
    end

    test "imperial ounces" do
      assert Units.to_display(29.5735295625, :volume, :imperial) == 1.0
      assert Units.format(29.5735295625, :volume, :imperial) == "1 oz"
    end
  end
end
