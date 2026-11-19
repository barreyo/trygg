defmodule Trygg.Reports.InsightsRefinementsTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias Trygg.Reports.Day
  alias Trygg.Reports.Insights

  defp child do
    %Child{timezone: "Etc/UTC", day_start: ~T[08:00:00], night_start: ~T[20:00:00]}
  end

  defp sleep(start, finish) do
    %Entry{
      id: System.unique_integer([:positive]),
      type: :sleep,
      started_at: start,
      ended_at: finish,
      data: %{}
    }
  end

  defp dt(%Date{} = date, %Time{} = time), do: DateTime.new!(date, time, "Etc/UTC")

  # A night that starts on `date`: `{bed, wake}` is one unbroken sleep,
  # `{bed, first_end, resume, wake}` is a first sleep, a feed, then more sleep
  # (everything after bed falls on the next date).
  defp night(date, {bed, wake}) do
    [sleep(dt(date, bed), dt(Date.add(date, 1), wake))]
  end

  defp night(date, {bed, first_end, resume, wake}) do
    next = Date.add(date, 1)

    [
      sleep(dt(date, bed), dt(next, first_end)),
      sleep(dt(next, resume), dt(next, wake))
    ]
  end

  @unbroken {~T[20:00:00], ~T[07:00:00]}
  # 6.5h first sleep, a 30 minute feed, then sleep until half past seven.
  @long_first {~T[21:00:00], ~T[03:30:00], ~T[04:00:00], ~T[07:30:00]}

  defp build_days(entries, dates, now), do: Enum.map(dates, &Day.build(child(), &1, entries, now))

  # Complete nights from the evening before `from` up to the one before `to`
  # (the morning of `to` is the last wake), and the dates `from..to-1`.
  defp history(shape, from, to) do
    last = Date.add(to, -1)
    entries = Enum.flat_map(Date.range(Date.add(from, -1), last), &night(&1, shape))
    {entries, Enum.to_list(Date.range(from, last))}
  end

  # `dates` start the window; it runs through the day before `today`.
  defp summarize(entries, dates, today, now, opts \\ []) do
    dates = Date.range(hd(dates), Date.add(today, -1)) |> Enum.to_list()
    days = build_days(entries, dates, now)
    today_day = Day.build(child(), today, entries, now)
    Insights.summarize(child(), days, today_day, now, opts)
  end

  describe "the night in progress" do
    setup do
      {entries, dates} = history(@long_first, ~D[2026-03-01], ~D[2026-03-10])
      %{entries: entries, dates: dates}
    end

    test "predicts the first feed from how long that stretch usually lasts", ctx do
      # Asleep since 21:00 on the 10th.
      entries = ctx.entries ++ [sleep(~U[2026-03-10 21:00:00Z], nil)]
      now = ~U[2026-03-10 22:00:00Z]
      today = ~D[2026-03-10]

      %{prediction: p} = summarize(entries, ctx.dates, today, now)

      assert p.state == :asleep
      assert %{feeds_so_far: 0, next_feed: feed} = p.night
      assert feed.at == ~U[2026-03-11 03:30:00Z]
      assert feed.in_seconds == 5 * 3600 + 30 * 60
      assert feed.nights >= 3

      # The night is 10.5h long: tomorrow's wake from bedtime plus that. (The
      # top-level morning wake is still this morning's actual one.)
      assert p.morning_wake.actual? == true
      assert p.night.morning_wake.actual? == false
      assert p.night.morning_wake.at == ~U[2026-03-11 07:30:00Z]
    end

    test "still predicts it after midnight, from the night's start the evening before", ctx do
      entries = ctx.entries ++ [sleep(~U[2026-03-10 21:00:00Z], nil)]
      now = ~U[2026-03-11 02:00:00Z]

      %{prediction: p} = summarize(entries, ctx.dates, ~D[2026-03-11], now)

      assert %{next_feed: feed} = p.night
      assert feed.at == ~U[2026-03-11 03:30:00Z]
      assert feed.in_seconds == 90 * 60
      # Past midnight the day's own morning wake is the one still to come.
      assert p.morning_wake.actual? == false
      assert p.morning_wake.at == ~U[2026-03-11 07:30:00Z]
    end

    test "after the feed it counts the wakings so far and predicts the morning", ctx do
      entries =
        ctx.entries ++
          [
            sleep(~U[2026-03-10 21:00:00Z], ~U[2026-03-11 03:30:00Z]),
            sleep(~U[2026-03-11 04:00:00Z], nil)
          ]

      now = ~U[2026-03-11 05:00:00Z]

      %{prediction: p} = summarize(entries, ctx.dates, ~D[2026-03-11], now)

      # No history of stretches after a feed (one feed a night), so no second
      # feed is invented.
      assert %{feeds_so_far: 1, next_feed: nil} = p.night
      assert p.morning_wake.at == ~U[2026-03-11 07:30:00Z]
    end

    test "is nil during a nap and for an awake child", ctx do
      now = ~U[2026-03-10 12:30:00Z]
      entries = ctx.entries ++ [sleep(~U[2026-03-10 12:00:00Z], nil)]
      %{prediction: napping} = summarize(entries, ctx.dates, ~D[2026-03-10], now)
      assert napping.state == :asleep
      assert napping.night == nil

      %{prediction: awake} = summarize(ctx.entries, ctx.dates, ~D[2026-03-10], now)
      assert awake.state == :awake
      assert awake.night == nil
    end

    test "needs a few nights of history before it says anything" do
      {entries, dates} = history(@long_first, ~D[2026-03-01], ~D[2026-03-02])
      entries = entries ++ [sleep(~U[2026-03-02 21:00:00Z], nil)]

      %{prediction: p} = summarize(entries, dates, ~D[2026-03-02], ~U[2026-03-02 22:00:00Z])

      assert %{next_feed: nil} = p.night
    end
  end

  describe "the next feed depends on the time of night and how long she has slept" do
    # Evenings alternate: a top-up feed 45 minutes after the 20:00 feed, or the
    # long sleep straight through to 02:00. After midnight she wakes about 3.5h
    # after the last feed.
    defp evening_entries(date, kind) do
      at = fn time ->
        if Time.compare(time, ~T[12:00:00]) == :lt,
          do: dt(Date.add(date, 1), time),
          else: dt(date, time)
      end

      segments =
        case kind do
          :top_up ->
            [
              {~T[18:00:00], ~T[19:30:00]},
              {~T[20:00:00], ~T[20:45:00]},
              {~T[21:15:00], ~T[03:45:00]},
              {~T[04:15:00], ~T[08:00:00]}
            ]

          :long ->
            [
              {~T[18:00:00], ~T[19:30:00]},
              {~T[20:00:00], ~T[02:00:00]},
              {~T[02:30:00], ~T[08:00:00]}
            ]
        end

      for {from, to} <- segments, do: sleep(at.(from), at.(to))
    end

    setup do
      dates = Date.range(~D[2026-03-01], ~D[2026-03-10]) |> Enum.to_list()

      entries =
        for {date, i} <- Enum.with_index([~D[2026-02-28] | dates]),
            entry <- evening_entries(date, if(rem(i, 2) == 0, do: :top_up, else: :long)),
            do: entry

      # Tonight: down at 18:00, fed at 19:30, asleep again from 20:00.
      tonight = [
        sleep(~U[2026-03-11 18:00:00Z], ~U[2026-03-11 19:30:00Z]),
        sleep(~U[2026-03-11 20:00:00Z], nil)
      ]

      %{entries: entries ++ tonight, dates: dates}
    end

    test "once she has slept past the short gaps, only the long ones count", ctx do
      %{prediction: p} =
        summarize(ctx.entries, ctx.dates, ~D[2026-03-11], ~U[2026-03-11 21:30:00Z])

      assert %{feeds_so_far: 1, next_feed: feed} = p.night
      # Past an hour and a half, the 45 minute top-ups are ruled out.
      assert DateTime.compare(feed.at, ~U[2026-03-12 01:50:00Z]) != :lt
      assert DateTime.compare(feed.at, ~U[2026-03-12 04:00:00Z]) == :lt
    end

    test "just after a feed, the short gaps still count", ctx do
      %{prediction: early} =
        summarize(ctx.entries, ctx.dates, ~D[2026-03-11], ~U[2026-03-11 20:10:00Z])

      %{prediction: late} =
        summarize(ctx.entries, ctx.dates, ~D[2026-03-11], ~U[2026-03-11 21:30:00Z])

      assert DateTime.compare(early.night.next_feed.at, late.night.next_feed.at) == :lt
    end
  end

  describe "the morning wake from the night's length" do
    test "a late bedtime carries through to a late wake" do
      {entries, dates} = history(@long_first, ~D[2026-03-01], ~D[2026-03-10])
      # Tonight she went down at 23:00 instead of 21:00.
      entries = entries ++ [sleep(~U[2026-03-10 23:00:00Z], nil)]
      now = ~U[2026-03-10 23:30:00Z]

      %{prediction: p} = summarize(entries, dates, ~D[2026-03-10], now)

      %{prediction: legacy} =
        summarize(entries, dates, ~D[2026-03-10], now, features: Insights.legacy_features())

      # Clock only says 07:30; bedtime + a 10.5h night says 09:30; a perfectly
      # steady history of both blends them evenly.
      assert legacy.night.morning_wake.at == ~U[2026-03-11 07:30:00Z]
      assert legacy.night.morning_wake.source == :clock
      assert p.night.morning_wake.source == :blended
      assert p.night.morning_wake.at == ~U[2026-03-11 08:30:00Z]
    end
  end

  describe "the bedtime range" do
    setup do
      # Bedtimes spread over an hour, one nap a day.
      bedtimes = [
        ~T[19:30:00],
        ~T[20:00:00],
        ~T[20:30:00],
        ~T[20:00:00],
        ~T[19:45:00],
        ~T[20:15:00]
      ]

      entries =
        for {bed, i} <- Enum.with_index(bedtimes), reduce: [] do
          acc ->
            date = Date.add(~D[2026-03-01], i)
            acc ++ night(date, {bed, ~T[07:00:00]})
        end ++ night(~D[2026-02-28], @unbroken)

      dates = for i <- 0..5, do: Date.add(~D[2026-03-01], i)
      now = ~U[2026-03-07 10:00:00Z]
      %{entries: entries, dates: dates, now: now}
    end

    test "comes from the spread of the child's own bedtimes", ctx do
      %{prediction: p} = summarize(ctx.entries, ctx.dates, ~D[2026-03-07], ctx.now)

      assert %{source: :history, from: from, to: to} = p.bedtime.range
      assert DateTime.compare(from, p.bedtime.at) == :lt
      assert DateTime.compare(to, p.bedtime.at) == :gt
      # Symmetric about the estimate.
      assert DateTime.diff(p.bedtime.at, from) == DateTime.diff(to, p.bedtime.at)
    end

    test "is sized from the ledger's misses when it has enough of them", ctx do
      opts = [accuracy: %{bedtime: %{mae_seconds: 20 * 60, n: 6}}]
      %{prediction: p} = summarize(ctx.entries, ctx.dates, ~D[2026-03-07], ctx.now, opts)

      assert p.bedtime.range.source == :ledger
      # 1.25 x the 20 minute MAE, each side.
      assert DateTime.diff(p.bedtime.at, p.bedtime.range.from) == 25 * 60
    end

    test "ignores a ledger that has too few misses", ctx do
      opts = [accuracy: %{bedtime: %{mae_seconds: 20 * 60, n: 2}}]
      %{prediction: p} = summarize(ctx.entries, ctx.dates, ~D[2026-03-07], ctx.now, opts)

      assert p.bedtime.range.source == :history
    end
  end

  describe "a shift in the child's own pattern" do
    test "shortens the half-life so recent nights win sooner" do
      dates = for d <- 1..17, do: Date.new!(2026, 3, d)

      shape = fn date ->
        if Date.compare(date, ~D[2026-03-14]) == :lt,
          do: @unbroken,
          else: {~T[23:00:00], ~T[05:00:00]}
      end

      entries = Enum.flat_map([~D[2026-02-28] | dates], &night(&1, shape.(&1)))
      now = ~U[2026-03-18 12:00:00Z]
      today = ~D[2026-03-18]

      %{prediction: p} =
        summarize(entries, dates, today, now, features: %{shift_half_life: true})

      %{prediction: slow} = summarize(entries, dates, today, now)

      # Both lean late, but re-locking faster gets further toward the new 23:00.
      assert DateTime.compare(p.bedtime.at, slow.bedtime.at) == :gt
    end

    test "notices a longer first stretch even when the amount of sleep is unchanged" do
      dates = for d <- 1..14, do: Date.new!(2026, 3, d)

      # Same bedtime, same wake, same night's sleep; the feed just moves from
      # 4h in to 6.5h in. `Shifts` (amounts only) can't see that.
      shape = fn date ->
        if Date.compare(date, ~D[2026-03-11]) == :lt,
          do: {~T[20:00:00], ~T[00:00:00], ~T[00:30:00], ~T[07:00:00]},
          else: {~T[20:00:00], ~T[02:30:00], ~T[03:00:00], ~T[07:00:00]}
      end

      entries = Enum.flat_map([~D[2026-02-28] | dates], &night(&1, shape.(&1)))
      # Asleep since 20:00 on the 15th.
      entries = entries ++ [sleep(~U[2026-03-15 20:00:00Z], nil)]
      now = ~U[2026-03-15 21:00:00Z]

      %{prediction: p} =
        summarize(entries, dates, ~D[2026-03-15], now, features: %{shift_half_life: true})

      %{prediction: slow} = summarize(entries, dates, ~D[2026-03-15], now)

      new_feed = ~U[2026-03-16 02:30:00Z]
      # Re-locking faster gets nearer the new 6.5h stretch than the slow half-life.
      assert abs(DateTime.diff(p.night.next_feed.at, new_feed)) <
               abs(DateTime.diff(slow.night.next_feed.at, new_feed))
    end

    test "an explicit half-life wins over the detected one" do
      dates = for d <- 1..17, do: Date.new!(2026, 3, d)

      shape = fn date ->
        if Date.compare(date, ~D[2026-03-14]) == :lt,
          do: @unbroken,
          else: {~T[23:00:00], ~T[05:00:00]}
      end

      entries = Enum.flat_map([~D[2026-02-28] | dates], &night(&1, shape.(&1)))
      now = ~U[2026-03-18 12:00:00Z]

      %{prediction: a} =
        summarize(entries, dates, ~D[2026-03-18], now,
          half_life_days: 6,
          features: %{shift_half_life: true}
        )

      %{prediction: b} = summarize(entries, dates, ~D[2026-03-18], now, half_life_days: 6)

      assert a.bedtime.at == b.bedtime.at
    end

    test "is opt-in: by default the half-life is left alone" do
      dates = for d <- 1..17, do: Date.new!(2026, 3, d)

      shape = fn date ->
        if Date.compare(date, ~D[2026-03-14]) == :lt,
          do: @unbroken,
          else: {~T[23:00:00], ~T[05:00:00]}
      end

      entries = Enum.flat_map([~D[2026-02-28] | dates], &night(&1, shape.(&1)))
      now = ~U[2026-03-18 12:00:00Z]

      %{prediction: default} = summarize(entries, dates, ~D[2026-03-18], now)

      %{prediction: off} =
        summarize(entries, dates, ~D[2026-03-18], now, features: %{shift_half_life: false})

      assert default.bedtime.at == off.bedtime.at
    end
  end

  test "legacy_features switches every refinement off" do
    assert Insights.legacy_features() |> Map.values() |> Enum.all?(&(&1 == false))
    assert map_size(Insights.legacy_features()) == 2
  end
end
