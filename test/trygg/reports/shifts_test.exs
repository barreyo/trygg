defmodule Trygg.Reports.ShiftsTest do
  use ExUnit.Case, async: true

  import Trygg.ReportDays

  alias Trygg.Reports.Feeding
  alias Trygg.Reports.Shifts

  @today ~D[2026-03-20]
  @now DateTime.new!(~D[2026-03-20], ~T[12:00:00], "Etc/UTC")

  # 18 days: 14 baseline, 3 recent, today (partial).
  defp dates, do: dates_ending(@today, 18)

  defp recent?(date), do: Date.diff(@today, date) in 1..3

  defp days(opts_fun) do
    build_days(child(), dates(), sleep_days(dates(), opts_fun), @now)
  end

  test "needs a baseline before reporting anything" do
    few = dates_ending(@today, 5)
    days = build_days(child(), few, sleep_days(few), @now)
    summary = Shifts.summarize(days)

    refute summary.ready?
    assert summary.sleep == []
    assert summary.growth_burst == %{active?: false}
  end

  test "a stable schedule produces no findings" do
    summary = Shifts.summarize(days(fn _ -> [] end))

    assert summary.ready?
    assert summary.baseline_days == 14
    assert summary.recent_days == 3
    assert summary.sleep == []
    refute summary.growth_burst.active?
  end

  test "a shorter night stretch in the last three days is a sleep shift" do
    # Recent nights: wake at 04:30 instead of 07:00 → overnight stretch 2.5 h shorter.
    summary =
      Shifts.summarize(days(fn date -> if recent?(date), do: [wake: ~T[04:30:00]], else: [] end))

    assert %{metric: :overnight_sleep, direction: :down} =
             Enum.find(summary.sleep, &(&1.metric == :overnight_sleep))

    assert Enum.find(summary.sleep, &(&1.metric == :total_sleep)).direction == :down
  end

  test "a big jump in sleep on the last day is a growth-burst signal" do
    long_naps = [
      {~T[09:00:00], ~T[11:00:00]},
      {~T[12:30:00], ~T[14:30:00]},
      {~T[15:30:00], ~T[17:30:00]}
    ]

    summary =
      Shifts.summarize(
        days(fn date -> if Date.diff(@today, date) == 1, do: [naps: long_naps], else: [] end)
      )

    assert summary.growth_burst.active?
    assert summary.growth_burst.sleep_days == 1
    assert summary.growth_burst.extra_sleep_seconds >= 4 * 3600
    assert summary.growth_burst.on == Date.add(@today, -1)
  end

  test "feeding volume up in the recent days is reported alongside sleep" do
    feeds =
      Enum.flat_map(dates(), fn date ->
        count = if date == @today, do: 3, else: 6
        ml = if recent?(date), do: 130, else: 90
        feed_day(date, count: count, ml: ml)
      end)

    sleep = sleep_days(dates())
    days = build_days(child(), dates(), sleep ++ feeds, @now)
    feeding = Feeding.summarize(child(), days, @now)
    summary = Shifts.summarize(days, feeding)

    assert %{metric: :feed_ml, direction: :up} =
             Enum.find(summary.feeding, &(&1.metric == :feed_ml))

    assert summary.sleep == []
  end
end
