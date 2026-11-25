defmodule Trygg.Reports.ScheduleFitTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Reports.ScheduleFit

  @child %Child{timezone: "Etc/UTC"}

  defp at(day, hour, minute \\ 0),
    do: DateTime.new!(Date.add(~D[2026-11-01], day), Time.new!(hour, minute, 0), "Etc/UTC")

  # A day with `naps` naps, wake windows of `windows` minutes before each nap,
  # bedtime at 19:00 + `bed_late` and waking at 07:00 + `wake_late`.
  defp day(i, opts) do
    windows = Keyword.get(opts, :windows, [90, 90, 90])

    %{
      now?: Keyword.get(opts, :now?, false),
      total_sleep_seconds: Keyword.get(opts, :sleep, 40_000),
      naps: Enum.map(windows, fn _ -> %{} end),
      wake_windows:
        windows
        |> Enum.with_index(1)
        |> Enum.map(fn {w, ordinal} -> %{ordinal: ordinal, seconds: w * 60, open?: false} end),
      bedtime: at(i, 19, Keyword.get(opts, :bed_late, 0)),
      morning_wake: at(i, 7, Keyword.get(opts, :wake_late, 0))
    }
  end

  defp effective(attrs \\ []) do
    Map.merge(
      %{
        mode: :guide,
        nap_count: %{value: 3},
        slots: for(i <- 1..3, do: %{ordinal: i, window: %{minutes: 90}}),
        bedtime: %{source: :guide, minutes: 19 * 60},
        wake: %{source: :guide, minutes: 7 * 60}
      },
      Map.new(attrs)
    )
  end

  test "nothing without a schedule" do
    assert ScheduleFit.score(@child, nil, [day(0, [])]) == nil
  end

  test "waits for enough complete days, and today and empty days don't count" do
    days = for i <- 0..3, do: day(i, [])
    assert %{ready?: false, days: 4} = ScheduleFit.score(@child, effective(), days)

    more = days ++ [day(4, now?: true), day(5, sleep: 0)]
    assert %{ready?: false, days: 4} = ScheduleFit.score(@child, effective(), more)

    assert %{ready?: true, days: 5} = ScheduleFit.score(@child, effective(), days ++ [day(6, [])])
  end

  test "counts the days with the scheduled number of naps" do
    days =
      for i <- 0..5 do
        if i < 4, do: day(i, windows: [90, 90, 90]), else: day(i, windows: [90, 90])
      end

    assert %{naps: %{scheduled: 3, matched: 4, median: 3.0}} =
             ScheduleFit.score(@child, effective(), days)
  end

  test "compares the time awake before each nap with the schedule's window" do
    days = for i <- 0..5, do: day(i, windows: [105, 90, 70])

    assert %{windows: [first, second, third]} = ScheduleFit.score(@child, effective(), days)
    assert %{ordinal: 1, scheduled: 90, median: 105, delta: 15, n: 6} = first
    assert %{ordinal: 2, delta: 0} = second
    assert %{ordinal: 3, delta: -20} = third
  end

  test "leaves out a nap with too few windows to go on" do
    days = for i <- 0..5, do: day(i, windows: [90])
    assert %{windows: [%{ordinal: 1}]} = ScheduleFit.score(@child, effective(), days)
  end

  test "holds bedtime and wake-up against the ones chosen, and only those" do
    days = for i <- 0..5, do: day(i, bed_late: 20, wake_late: 0)

    # Not chosen: nothing to hold them against.
    assert %{bedtime: nil, wake: nil} = ScheduleFit.score(@child, effective(), days)

    pinned =
      effective(
        bedtime: %{source: :pinned, minutes: 19 * 60},
        wake: %{source: :pinned, minutes: 7 * 60 - 45}
      )

    assert %{bedtime: bed, wake: wake} = ScheduleFit.score(@child, pinned, days)
    assert %{scheduled: 1140, n: 6, median_delta: 20, close: 6} = bed
    assert %{median_delta: 45, close: 0} = wake
  end

  test "a bedtime after midnight counts as late, not early" do
    days =
      for i <- 0..5 do
        %{day(i, []) | bedtime: DateTime.add(at(i, 0), 86_400 + 30 * 60, :second)}
      end

    pinned = effective(bedtime: %{source: :pinned, minutes: 23 * 60})
    assert %{bedtime: %{median_delta: 90}} = ScheduleFit.score(@child, pinned, days)
  end

  test "a newborn's rhythm has no naps or windows to score" do
    eff = %{mode: :newborn, bedtime: nil, wake: %{source: :pinned, minutes: 7 * 60}}
    days = for i <- 0..5, do: day(i, [])

    assert %{ready?: true, naps: nil, windows: [], bedtime: nil, wake: %{median_delta: 0}} =
             ScheduleFit.score(@child, eff, days)
  end
end
