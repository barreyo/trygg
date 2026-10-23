defmodule Trygg.Reports.FeedAmountTest do
  use ExUnit.Case, async: true

  alias Trygg.Reports.FeedAmount

  defp point(ml, seconds, period \\ :day), do: %{ml: ml, seconds: seconds, period: period}

  # 60/90/120 ml feeds, each buying 45/60/75 minutes: bigger feed, longer gap.
  defp proportional(n) do
    for i <- 0..(n - 1) do
      ml = Enum.at([60, 90, 120], rem(i, 3))
      point(ml, 3600 + (ml - 90) * 30)
    end
  end

  test "a bigger-than-usual feed pushes the estimate out, a smaller one pulls it in" do
    points = proportional(24)

    big = FeedAmount.estimate(points, :day, 120)
    small = FeedAmount.estimate(points, :day, 60)
    typical = FeedAmount.estimate(points, :day, 90)

    assert big.baseline == 3600.0
    assert_in_delta big.seconds, 4500, 1
    assert_in_delta small.seconds, 2700, 1
    assert_in_delta typical.seconds, 3600, 1
    assert big.typical_ml == 90.0
    assert {lo, hi} = big.range
    assert lo <= big.seconds and big.seconds <= hi
  end

  test "stays out of the way when the amount does not predict the gap" do
    # 3 volumes against 4 gaps over 24 intervals: every pairing is equally common.
    points =
      for i <- 0..23 do
        point(Enum.at([60, 90, 120], rem(i, 3)), Enum.at([3000, 3600, 4200, 3600], rem(i, 4)))
      end

    assert FeedAmount.estimate(points, :day, 120) == nil
  end

  test "stays out of the way when bigger feeds buy shorter gaps" do
    points =
      for i <- 0..23 do
        ml = Enum.at([60, 90, 120], rem(i, 3))
        point(ml, 3600 - (ml - 90) * 30)
      end

    assert FeedAmount.estimate(points, :day, 120) == nil
  end

  test "needs enough history to backtest" do
    assert FeedAmount.estimate(proportional(12), :day, 120) == nil
    assert FeedAmount.estimate(proportional(13), :day, 120)
  end

  test "ignores intervals and feeds without an amount" do
    assert FeedAmount.estimate(proportional(24), :day, 0) == nil
    assert FeedAmount.estimate(proportional(24), :day, nil) == nil
    assert FeedAmount.estimate(Enum.map(proportional(24), &%{&1 | ml: 0}), :day, 90) == nil
  end

  test "compares each feed with its own period so night size does not look like an effect" do
    # Night feeds are bigger and further apart, but within a period the amount
    # says nothing about the gap.
    day = for i <- 0..11, do: point(60 + rem(i, 2) * 10, 3600 + rem(i, 3) * 300)
    night = for i <- 0..11, do: point(150 + rem(i, 2) * 10, 9000 + rem(i, 3) * 300, :night)

    assert FeedAmount.estimate(
             Enum.zip_with(day, night, &[&1, &2]) |> List.flatten(),
             :night,
             160
           ) ==
             nil
  end
end
