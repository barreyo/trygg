defmodule Trygg.Reports.InsightsTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias Trygg.Reports.Day
  alias Trygg.Reports.Insights
  alias Trygg.Reports.Norms

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

  defp two_nap_day(date, {n1s, n1e}, {n2s, n2e}) do
    prev = Date.add(date, -1)
    base = date.day * 10

    entries = [
      sleep(base, datetime(prev, ~T[20:00:00]), datetime(date, ~T[07:00:00])),
      sleep(base + 1, datetime(date, n1s), datetime(date, n1e)),
      sleep(base + 2, datetime(date, n2s), datetime(date, n2e)),
      sleep(base + 3, datetime(date, ~T[19:30:00]), datetime(Date.add(date, 1), ~T[07:00:00]))
    ]

    Day.build(child(), date, entries, datetime(Date.add(date, 1), ~T[12:00:00]))
  end

  defp nap_day(date, naps, wake \\ ~T[07:00:00]) do
    prev = Date.add(date, -1)
    base = date.day * 10

    nap_entries =
      naps
      |> Enum.with_index(1)
      |> Enum.map(fn {{s, e}, i} -> sleep(base + i, datetime(date, s), datetime(date, e)) end)

    entries =
      [sleep(base, datetime(prev, ~T[20:00:00]), datetime(date, wake))] ++
        nap_entries ++
        [
          sleep(
            base + 99,
            datetime(date, ~T[19:30:00]),
            datetime(Date.add(date, 1), ~T[07:00:00])
          )
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

  test "blends the age prior with a few days of history" do
    # ~94 days old on 2026-03-05.
    child = %{child() | birth_date: ~D[2025-12-01]}

    # Two recent days with a short 1h first wake window — well under the ~90 min
    # age prior — so the blend must land between the two.
    history =
      for date <- [~D[2026-03-03], ~D[2026-03-04]] do
        typical_day(date, nap1: {~T[08:00:00], ~T[09:00:00]}, id: date.day * 10)
      end

    now = ~U[2026-03-05 07:30:00Z]

    today =
      Day.build(
        child,
        ~D[2026-03-05],
        [sleep(50, ~U[2026-03-04 20:00:00Z], ~U[2026-03-05 07:00:00Z])],
        now
      )

    %{prediction: p} = Insights.summarize(child, history, today, now)

    assert p.next_nap.source == :blended
    offset = DateTime.diff(p.next_nap.at, ~U[2026-03-05 07:00:00Z], :second)
    assert offset > 3600 and offset < 5442
  end

  test "a child with no sleep history still gets a next-nap prediction" do
    child = %{child() | birth_date: ~D[2026-02-20]}
    now = ~U[2026-03-05 10:00:00Z]

    today =
      Day.build(
        child,
        ~D[2026-03-05],
        [
          sleep(1, ~U[2026-03-04 22:00:00Z], ~U[2026-03-05 07:00:00Z]),
          sleep(2, ~U[2026-03-05 08:00:00Z], ~U[2026-03-05 08:45:00Z])
        ],
        now
      )

    %{prediction: p} = Insights.summarize(child, [], today, now)

    assert p.next_nap
    assert p.next_nap.source == :age_prior
    assert p.next_nap.ordinal == 2
  end

  test "recent days dominate the wake-window estimate" do
    child = child()

    old =
      for date <- [~D[2026-02-20], ~D[2026-02-21], ~D[2026-02-22], ~D[2026-02-23]] do
        typical_day(date, nap1: {~T[09:00:00], ~T[10:00:00]}, id: date.day * 10)
      end

    recent =
      for date <- [~D[2026-03-01], ~D[2026-03-02], ~D[2026-03-03]] do
        typical_day(date, nap1: {~T[10:00:00], ~T[11:00:00]}, id: date.day * 10)
      end

    now = ~U[2026-03-04 08:00:00Z]

    today =
      Day.build(
        child,
        ~D[2026-03-04],
        [sleep(99, ~U[2026-03-03 20:00:00Z], ~U[2026-03-04 07:00:00Z])],
        now
      )

    %{prediction: p} = Insights.summarize(child, old ++ recent, today, now)

    assert p.next_nap.source == :history
    offset = DateTime.diff(p.next_nap.at, ~U[2026-03-04 07:00:00Z], :second)
    # Unweighted this would be ~2.4h; recency weighting pulls it to the recent 3h.
    assert offset > 2.6 * 3600
  end

  test "a short nap pulls the next nap earlier than a full nap does" do
    # ~111 days old on 2026-03-06. Naps start well after the 07:00 wake so they
    # don't fold into the overnight cluster.
    child = %{child() | birth_date: ~D[2025-11-15]}

    history =
      for date <- [~D[2026-03-02], ~D[2026-03-03], ~D[2026-03-04], ~D[2026-03-05]] do
        two_nap_day(date, {~T[09:30:00], ~T[11:00:00]}, {~T[13:00:00], ~T[14:00:00]})
      end

    now = ~U[2026-03-06 11:15:00Z]
    night = sleep(60, ~U[2026-03-05 20:00:00Z], ~U[2026-03-06 07:00:00Z])

    full =
      Day.build(
        child,
        ~D[2026-03-06],
        [night, sleep(61, ~U[2026-03-06 09:30:00Z], ~U[2026-03-06 11:00:00Z])],
        now
      )

    short =
      Day.build(
        child,
        ~D[2026-03-06],
        [night, sleep(61, ~U[2026-03-06 09:30:00Z], ~U[2026-03-06 10:05:00Z])],
        now
      )

    %{prediction: pf} = Insights.summarize(child, history, full, now)
    %{prediction: ps} = Insights.summarize(child, history, short, now)

    assert ps.next_nap.ordinal == 2
    assert DateTime.diff(pf.next_nap.at, ps.next_nap.at, :second) > 20 * 60
  end

  test "a wake window is never predicted below the age floor after a tiny catnap" do
    # ~11 days old on 2026-03-07 → 20-minute floor. Nap-2 start clock is spread
    # wide across the history so the clock anchor stays off and the prediction
    # is a pure (clamped) wake window.
    child = %{child() | birth_date: ~D[2026-02-24]}

    history = [
      two_nap_day(~D[2026-03-03], {~T[09:00:00], ~T[09:30:00]}, {~T[09:33:00], ~T[10:30:00]}),
      two_nap_day(~D[2026-03-04], {~T[10:30:00], ~T[11:00:00]}, {~T[11:03:00], ~T[12:00:00]}),
      two_nap_day(~D[2026-03-05], {~T[09:15:00], ~T[09:45:00]}, {~T[09:48:00], ~T[10:45:00]}),
      two_nap_day(~D[2026-03-06], {~T[10:00:00], ~T[10:30:00]}, {~T[10:33:00], ~T[11:30:00]})
    ]

    now = ~U[2026-03-07 09:40:00Z]
    night = sleep(70, ~U[2026-03-06 20:00:00Z], ~U[2026-03-07 07:00:00Z])

    today =
      Day.build(
        child,
        ~D[2026-03-07],
        [night, sleep(71, ~U[2026-03-07 09:30:00Z], ~U[2026-03-07 09:35:00Z])],
        now
      )

    %{prediction: p} = Insights.summarize(child, history, today, now)
    offset = DateTime.diff(p.next_nap.at, ~U[2026-03-07 09:35:00Z], :second)
    floor = Norms.min_wake_window_seconds(11)

    assert offset >= floor
    # Pinned at the floor — the 3-min history windows would otherwise blend far lower.
    assert offset <= floor + 120
  end

  test "clock anchoring damps how much a late nap 1 shifts later naps" do
    # ~150 days old; a rock-steady 3-nap clock (09:30 / 12:30 / 15:30).
    child = %{child() | birth_date: ~D[2025-10-07]}

    history =
      for date <- [~D[2026-03-02], ~D[2026-03-03], ~D[2026-03-04], ~D[2026-03-05]] do
        nap_day(date, [
          {~T[09:30:00], ~T[10:30:00]},
          {~T[12:30:00], ~T[13:30:00]},
          {~T[15:30:00], ~T[16:30:00]}
        ])
      end

    night = sleep(60, ~U[2026-03-05 20:00:00Z], ~U[2026-03-06 07:00:00Z])

    on_time =
      Day.build(
        child,
        ~D[2026-03-06],
        [night, sleep(61, ~U[2026-03-06 09:30:00Z], ~U[2026-03-06 10:30:00Z])],
        ~U[2026-03-06 10:45:00Z]
      )

    late =
      Day.build(
        child,
        ~D[2026-03-06],
        [night, sleep(61, ~U[2026-03-06 10:10:00Z], ~U[2026-03-06 11:10:00Z])],
        ~U[2026-03-06 11:25:00Z]
      )

    %{prediction: pa} = Insights.summarize(child, history, on_time, ~U[2026-03-06 10:45:00Z])
    %{prediction: pb} = Insights.summarize(child, history, late, ~U[2026-03-06 11:25:00Z])

    # Nap 1 slipped 40 min; nap 2's target should move by clearly less.
    drift2 = DateTime.diff(pb.next_nap.at, pa.next_nap.at, :second)
    assert drift2 > 0 and drift2 < 35 * 60

    nap3_a = Enum.find(pa.schedule, &(&1.ordinal == 3))
    nap3_b = Enum.find(pb.schedule, &(&1.ordinal == 3))
    drift3 = DateTime.diff(nap3_b.start, nap3_a.start, :second)
    # Later in the day the anchor is stronger, so nap 3 drifts even less.
    assert drift3 >= 0 and drift3 < drift2
  end

  test "erratic nap-start clocks fall back to a pure wake-window offset" do
    # ~82 days old. Every nap-1 wake window is exactly 60 min, but the clock
    # time swings from 08:00 to 13:00 across the history — so no clock anchor.
    child = %{child() | birth_date: ~D[2025-12-15]}

    history = [
      nap_day(~D[2026-03-02], [{~T[08:00:00], ~T[09:00:00]}], ~T[07:00:00]),
      nap_day(~D[2026-03-03], [{~T[11:00:00], ~T[12:00:00]}], ~T[10:00:00]),
      nap_day(~D[2026-03-04], [{~T[09:30:00], ~T[10:30:00]}], ~T[08:30:00]),
      nap_day(~D[2026-03-05], [{~T[13:00:00], ~T[14:00:00]}], ~T[12:00:00])
    ]

    now = ~U[2026-03-06 07:30:00Z]

    today =
      Day.build(
        child,
        ~D[2026-03-06],
        [sleep(60, ~U[2026-03-05 20:00:00Z], ~U[2026-03-06 07:00:00Z])],
        now
      )

    %{prediction: p} = Insights.summarize(child, history, today, now)

    # ~60-min history window (blended a little toward the age prior); nowhere
    # near the ~10:15 median nap-1 clock a live anchor would snap to.
    assert DateTime.compare(p.next_nap.at, ~U[2026-03-06 09:00:00Z]) == :lt
    assert DateTime.diff(p.next_nap.at, ~U[2026-03-06 07:00:00Z], :second) in 3000..4800
  end

  test "bedtime is pulled earlier when the day's naps run short" do
    # ~113 days old; steady 2-nap days of ~90 min each.
    child = %{child() | birth_date: ~D[2025-11-15]}

    history =
      for date <- [~D[2026-03-01], ~D[2026-03-02], ~D[2026-03-03], ~D[2026-03-04]] do
        two_nap_day(date, {~T[09:30:00], ~T[11:00:00]}, {~T[13:30:00], ~T[15:00:00]})
      end

    night = sleep(70, ~U[2026-03-04 20:00:00Z], ~U[2026-03-05 07:00:00Z])
    now = ~U[2026-03-05 16:00:00Z]

    short =
      Day.build(
        child,
        ~D[2026-03-05],
        [
          night,
          sleep(71, ~U[2026-03-05 09:30:00Z], ~U[2026-03-05 10:00:00Z]),
          sleep(72, ~U[2026-03-05 13:30:00Z], ~U[2026-03-05 14:00:00Z])
        ],
        now
      )

    full =
      Day.build(
        child,
        ~D[2026-03-05],
        [
          night,
          sleep(71, ~U[2026-03-05 09:30:00Z], ~U[2026-03-05 11:00:00Z]),
          sleep(72, ~U[2026-03-05 13:30:00Z], ~U[2026-03-05 15:00:00Z])
        ],
        now
      )

    %{prediction: ps} = Insights.summarize(child, history, short, now)
    %{prediction: pf} = Insights.summarize(child, history, full, now)

    assert ps.bedtime.shifted_by_seconds > 0
    assert pf.bedtime.shifted_by_seconds == 0
    assert DateTime.compare(ps.bedtime.at, pf.bedtime.at) == :lt
    # Never earlier than 18:00 local.
    assert DateTime.compare(ps.bedtime.at, ~U[2026-03-05 18:00:00Z]) != :lt
  end

  test "flags a suspected nap transition when the recent nap count drops" do
    child = %{child() | birth_date: ~D[2025-10-26]}

    # 8–18 days ago: three naps. Last week: down to two.
    older =
      for i <- 18..8//-1 do
        nap_day(Date.add(~D[2026-03-05], -i), [
          {~T[09:15:00], ~T[10:15:00]},
          {~T[11:45:00], ~T[12:45:00]},
          {~T[14:30:00], ~T[15:15:00]}
        ])
      end

    recent =
      for i <- 7..1//-1 do
        nap_day(Date.add(~D[2026-03-05], -i), [
          {~T[09:30:00], ~T[10:45:00]},
          {~T[13:15:00], ~T[14:30:00]}
        ])
      end

    now = ~U[2026-03-05 09:00:00Z]

    today =
      Day.build(
        child,
        ~D[2026-03-05],
        [sleep(99, ~U[2026-03-04 20:00:00Z], ~U[2026-03-05 07:00:00Z])],
        now
      )

    %{prediction: p} = Insights.summarize(child, older ++ recent, today, now)
    assert p.transition? == true

    # A child steady on two naps across the whole window is *not* flagged.
    steady =
      for i <- 18..1//-1 do
        nap_day(Date.add(~D[2026-03-05], -i), [
          {~T[09:30:00], ~T[10:45:00]},
          {~T[13:15:00], ~T[14:30:00]}
        ])
      end

    %{prediction: q} = Insights.summarize(child, steady, today, now)
    assert q.transition? == false
  end

  test "a per-kind ledger bias nudges the prediction, damped by half" do
    child = child()

    history =
      for date <- [~D[2026-03-01], ~D[2026-03-02], ~D[2026-03-03]] do
        typical_day(date, id: date.day * 10)
      end

    now = ~U[2026-03-04 09:00:00Z]

    today =
      Day.build(
        child,
        ~D[2026-03-04],
        [sleep(40, ~U[2026-03-03 20:00:00Z], ~U[2026-03-04 07:00:00Z])],
        now
      )

    %{prediction: base} = Insights.summarize(child, history, today, now)

    %{prediction: biased} =
      Insights.summarize(child, history, today, now, bias: %{next_nap: 1800})

    assert_in_delta DateTime.diff(biased.next_nap.at, base.next_nap.at, :second), 900, 5
  end

  test "falls back to an age-band prior when there is no wake-window history" do
    child = %{child() | birth_date: ~D[2025-12-01]}
    now = ~U[2026-03-05 07:30:00Z]

    today =
      Day.build(
        child,
        ~D[2026-03-05],
        [sleep(50, ~U[2026-03-04 20:00:00Z], ~U[2026-03-05 07:00:00Z])],
        now
      )

    %{prediction: p} = Insights.summarize(child, [], today, now)

    assert p.next_nap.source == :age_prior
    # 94 days old → ~68.6–112.9 min band, scaled by the 0.82 first-window
    # position factor → ~56–92 min after the 07:00 wake.
    assert p.next_nap.label == "08:14"
    assert p.next_nap.range.label == "07:56–08:32"
    assert p.wake_pressure.source == :age_prior
    assert p.wake_pressure.state == :fresh
  end

  test "a preterm baby's age prior uses corrected age" do
    # 94 days old, born at 30+0 weeks: corrected age is 24 days.
    preterm = %{child() | birth_date: ~D[2025-12-01], gestational_age_days: 210}
    term_twin = %{child() | birth_date: ~D[2026-02-09]}
    now = ~U[2026-03-05 07:30:00Z]
    night = [sleep(50, ~U[2026-03-04 20:00:00Z], ~U[2026-03-05 07:00:00Z])]

    %{prediction: p} =
      Insights.summarize(preterm, [], Day.build(preterm, ~D[2026-03-05], night, now), now)

    %{prediction: twin} =
      Insights.summarize(term_twin, [], Day.build(term_twin, ~D[2026-03-05], night, now), now)

    assert p.next_nap.source == :age_prior
    assert p.next_nap.label == twin.next_nap.label
    assert p.next_nap.range.label == twin.next_nap.range.label
    # Earlier than the 08:14 a term 94-day-old gets.
    assert p.next_nap.label < "08:14"
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
