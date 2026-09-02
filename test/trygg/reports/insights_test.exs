defmodule Trygg.Reports.InsightsTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias Trygg.Reports.Day
  alias Trygg.Reports.Insights

  defp child do
    %Child{
      timezone: "Etc/UTC",
      day_start: ~T[08:00:00],
      night_start: ~T[20:00:00]
    }
  end

  defp sleep(id, start, finish) do
    %Entry{id: id, type: :sleep, started_at: start, ended_at: finish, data: %{}}
  end

  defp typical_day(date, opts) do
    wake = Keyword.get(opts, :wake, ~T[07:00:00])
    bed = Keyword.get(opts, :bed, ~T[20:00:00])
    nap1 = Keyword.get(opts, :nap1, {~T[10:00:00], ~T[11:00:00]})
    id = Keyword.get(opts, :id, date.day * 10)
    prev = Date.add(date, -1)

    {nap1_start, nap1_end} = nap1

    entries = [
      sleep(id, datetime(prev, ~T[20:00:00]), datetime(date, wake)),
      sleep(id + 1, datetime(date, nap1_start), datetime(date, nap1_end)),
      sleep(id + 2, datetime(date, bed), datetime(Date.add(date, 1), ~T[07:00:00]))
    ]

    Day.build(child(), date, entries, datetime(Date.add(date, 1), ~T[12:00:00]))
  end

  defp datetime(%Date{} = date, %Time{} = time) do
    DateTime.new!(date, time, "Etc/UTC")
  end

  test "returns nils when there are fewer than 3 days" do
    d1 = typical_day(~D[2026-03-01], id: 10)
    d2 = typical_day(~D[2026-03-02], id: 20)
    now = ~U[2026-03-02 18:00:00Z]

    summary = Insights.summarize(child(), [d1, d2], d2, now)
    refute summary.ready?
    assert summary.totals.total.median == nil
    assert summary.heatmap == nil
    assert summary.morning_wake.median_label == nil
  end

  test "computes median morning wake, bedtime, and nap length" do
    days =
      for {date, wake} <- [
            {~D[2026-03-01], ~T[07:00:00]},
            {~D[2026-03-02], ~T[07:10:00]},
            {~D[2026-03-03], ~T[06:50:00]}
          ] do
        typical_day(date, wake: wake, id: date.day * 10)
      end

    today = List.last(days)
    summary = Insights.summarize(child(), days, today, ~U[2026-03-04 12:00:00Z])

    assert summary.ready?
    assert summary.morning_wake.median_label == "07:00"
    assert summary.bedtime.median_label == "20:00"
    assert hd(summary.naps.by_ordinal).median == 3600.0
    assert hd(summary.wake_windows.by_ordinal).n == 3
    assert hd(summary.totals.per_day).awake + hd(summary.totals.per_day).total == 86_400
  end

  test "per_day carries wake and bedtime as minutes from local midnight" do
    days =
      for {date, wake} <- [
            {~D[2026-03-01], ~T[07:00:00]},
            {~D[2026-03-02], ~T[07:10:00]},
            {~D[2026-03-03], ~T[06:50:00]}
          ] do
        typical_day(date, wake: wake, id: date.day * 10)
      end

    today = List.last(days)
    summary = Insights.summarize(child(), days, today, ~U[2026-03-04 12:00:00Z])

    assert Enum.map(summary.totals.per_day, & &1.wake_minutes) == [420, 430, 410]
    assert Enum.map(summary.totals.per_day, & &1.bed_minutes) == [1200, 1200, 1200]

    empty = Day.build(child(), ~D[2026-03-04], [], ~U[2026-03-04 12:00:00Z])
    summary = Insights.summarize(child(), [empty], empty, ~U[2026-03-04 12:00:00Z])
    assert [%{wake_minutes: nil, bed_minutes: nil}] = summary.totals.per_day
  end

  test "treats a bedtime after midnight as evening + 24h" do
    days =
      for date <- [~D[2026-03-01], ~D[2026-03-02], ~D[2026-03-03]] do
        typical_day(date, bed: ~T[00:30:00], id: date.day * 10)
        |> Map.put(:bedtime, datetime(Date.add(date, 1), ~T[00:30:00]))
      end

    # typical_day with bed 00:30 would put bedtime on the same calendar date at 00:30,
    # which is morning — override to next-day 00:30 as a late bedtime.
    days =
      Enum.map(days, fn day ->
        %{day | bedtime: datetime(Date.add(day.date, 1), ~T[00:30:00])}
      end)

    today = List.last(days)
    summary = Insights.summarize(child(), days, today, ~U[2026-03-04 12:00:00Z])
    assert summary.bedtime.median_label == "00:30"
    assert summary.bedtime.median_minutes == 24 * 60 + 30
  end

  test "slope is positive when total sleep is rising" do
    days =
      for {date, extra_hours} <- [
            {~D[2026-03-01], 0},
            {~D[2026-03-02], 1},
            {~D[2026-03-03], 2}
          ] do
        day = typical_day(date, id: date.day * 10)
        extra = extra_hours * 3600

        %{
          day
          | total_sleep_seconds: day.total_sleep_seconds + extra,
            day_sleep_seconds: day.day_sleep_seconds + extra
        }
      end

    summary = Insights.summarize(child(), days, List.last(days), ~U[2026-03-04 12:00:00Z])
    assert summary.totals.slope.minutes_per_day > 0
    assert summary.totals.slope.label =~ "+"
  end

  test "predicts the next nap from the current wake window ordinal" do
    history =
      for date <- [~D[2026-03-01], ~D[2026-03-02], ~D[2026-03-03]] do
        typical_day(date, id: date.day * 10)
      end

    today_date = ~D[2026-03-04]
    now = ~U[2026-03-04 09:00:00Z]

    today_entries = [
      sleep(40, ~U[2026-03-03 20:00:00Z], ~U[2026-03-04 07:00:00Z])
    ]

    today = Day.build(child(), today_date, today_entries, now)
    summary = Insights.summarize(child(), history, today, now)

    assert summary.prediction.state == :awake
    assert summary.prediction.morning_wake.actual?
    assert summary.prediction.next_nap.label
    assert summary.prediction.next_nap.in_seconds > 0
  end

  test "next nap carries an IQR range and wake pressure once history is rich enough" do
    # Four days with wake windows of 3h, 3h10, 2h50, 3h before the first nap.
    history =
      for {date, nap_start} <- [
            {~D[2026-03-01], ~T[10:00:00]},
            {~D[2026-03-02], ~T[10:10:00]},
            {~D[2026-03-03], ~T[09:50:00]},
            {~D[2026-03-04], ~T[10:00:00]}
          ] do
        typical_day(date, nap1: {nap_start, Time.add(nap_start, 3600)}, id: date.day * 10)
      end

    now = ~U[2026-03-05 09:00:00Z]

    today =
      Day.build(
        child(),
        ~D[2026-03-05],
        [sleep(50, ~U[2026-03-04 20:00:00Z], ~U[2026-03-05 07:00:00Z])],
        now
      )

    %{prediction: p} = Insights.summarize(child(), history, today, now)

    assert p.next_nap.source == :history
    assert p.next_nap.label == "10:00"
    assert p.next_nap.range.label =~ ~r/^09:5\d–10:0\d$/
    assert %{state: :fresh, awake_seconds: 7200, typical_seconds: 10_800.0} = p.wake_pressure

    late = ~U[2026-03-05 10:30:00Z]
    %{prediction: p} = Insights.summarize(child(), history, today, late)
    assert p.wake_pressure.state == :past
  end

  test "falls back to an age-band prior when there is no wake-window history" do
    child = %{child() | birth_date: ~D[2025-12-01]}
    now = ~U[2026-03-05 08:00:00Z]

    today =
      Day.build(
        child,
        ~D[2026-03-05],
        [sleep(50, ~U[2026-03-04 20:00:00Z], ~U[2026-03-05 07:00:00Z])],
        now
      )

    %{prediction: p} = Insights.summarize(child, [], today, now)

    assert p.next_nap.source == :age_prior
    # 94 days old → 75–120 min band, midpoint 97.5 min after 07:00
    assert p.next_nap.label == "08:37"
    assert p.next_nap.range.label == "08:15–09:00"
    assert p.wake_pressure.source == :age_prior
    assert p.wake_pressure.state == :fresh
  end

  test "prediction is asleep when a timer is running" do
    history =
      for date <- [~D[2026-03-01], ~D[2026-03-02], ~D[2026-03-03]] do
        typical_day(date, id: date.day * 10)
      end

    now = ~U[2026-03-04 10:30:00Z]

    today =
      Day.build(
        child(),
        ~D[2026-03-04],
        [
          sleep(40, ~U[2026-03-03 20:00:00Z], ~U[2026-03-04 07:00:00Z]),
          sleep(41, ~U[2026-03-04 10:00:00Z], nil)
        ],
        now
      )

    summary = Insights.summarize(child(), history, today, now)
    assert summary.prediction.state == :asleep
    assert summary.prediction.next_nap == nil
  end
end
