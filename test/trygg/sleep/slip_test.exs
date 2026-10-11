defmodule Trygg.Sleep.SlipTest do
  use ExUnit.Case, async: true

  alias Trygg.Sleep.Slip

  test "opens at four months corrected" do
    assert Slip.min_age_days() == 122
    assert Slip.definition().id == :slip
  end

  describe "checkin_interval/2" do
    test "night 1 is 5, 10, 15 minutes and on in fives" do
      assert Slip.schedule(1, 5) == [300, 600, 900, 1200, 1500]
    end

    test "each night starts five minutes later and grows five minutes a visit" do
      assert Slip.schedule(2) == [600, 900, 1200, 1500]
      assert Slip.schedule(3) == [900, 1200, 1500, 1800]
      assert Slip.schedule(5, 3) == [1500, 1800, 2100]
    end

    test "matches the book's 5-minute plan table" do
      for night <- 1..5, index <- 0..2 do
        assert Slip.checkin_interval(night, index) == 300 * (night + index)
      end
    end
  end

  test "expected crying eases over the first three nights" do
    assert %{lo: 45, hi: 90} = Slip.expected(1)
    assert %{lo: 20, hi: 45} = Slip.expected(2)
    assert %{lo: 0, hi: 25} = Slip.expected(3)
    assert Slip.expected(6).label == "Under 25 minutes"
  end

  test "there are ten pre-flight items with their own ids" do
    assert length(Slip.preflight()) == 10
    assert Enum.all?(Slip.preflight_ids(), &String.starts_with?(&1, "s-"))
  end

  describe "assess/1" do
    defp night(number, minutes),
      do: %{number: number, bedtime_to_sleep_seconds: minutes && minutes * 60}

    test "needs two nights" do
      assert {:early, _} = Slip.assess([])
      assert {:early, _} = Slip.assess([night(1, 60)])
    end

    test "improving when bedtime is quicker than night one" do
      assert {:improving, _} = Slip.assess([night(1, 70), night(2, 40), night(3, 15)])
    end

    test "a good night followed by a bad one is an extinction burst" do
      {status, text} = Slip.assess([night(1, 60), night(2, 20), night(3, 10), night(4, 45)])
      assert status == :burst
      assert text =~ "extinction burst"
    end

    test "about the same is steady" do
      assert {:steady, _} = Slip.assess([night(1, 40), night(2, 42)])
    end

    test "a week with no improvement is stuck, and sends you to the pediatrician" do
      nights = for n <- 1..7, do: night(n, 50)
      {status, text} = Slip.assess(nights)
      assert status == :stuck
      assert text =~ "pediatrician"
    end

    test "nights with no bedtime recorded are skipped" do
      assert {:early, _} = Slip.assess([night(1, nil), night(2, 30)])
    end
  end
end
