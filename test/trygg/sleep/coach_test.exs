defmodule Trygg.Sleep.CoachTest do
  use ExUnit.Case, async: true

  import Trygg.ReportDays

  alias Trygg.Reports.Day
  alias Trygg.Sleep.Coach

  @date ~D[2026-10-10]
  @newborn %{id: :newborn, label: "Newborn", week: 4, age_days: 28, next: nil}
  @foundations %{id: :foundations, label: "Foundations", week: 14, age_days: 100, next: nil}

  defp t(hour, minute \\ 0), do: at(@date, Time.new!(hour, minute, 0))

  defp stats(attrs \\ []) do
    base = %{sleeps: 0, cued: 0, overtired: 0, measured: 0, fed_to_sleep: 0}
    Map.merge(base, Map.new(attrs))
  end

  defp habits(week \\ [], cue_windows \\ %{}),
    do: %{today: stats(), week: stats(week), cue_windows: cue_windows}

  defp prediction(attrs \\ []) do
    Map.merge(
      %{
        state: :awake,
        next_nap: nil,
        wake_pressure: nil,
        schedule: [],
        morning_wake: nil,
        bedtime: nil,
        transition?: false
      },
      Map.new(attrs)
    )
  end

  defp ctx(attrs \\ []) do
    now = attrs[:now] || t(12)

    %{
      child: child(%{name: "Astrid"}),
      phase: @newborn,
      prediction: prediction(),
      today: Day.build(child(), @date, [], now),
      habits: habits(),
      last_feed_at: nil,
      now: now
    }
    |> Map.merge(Map.new(attrs))
  end

  defp ids(ctx), do: ctx |> Coach.insights() |> Enum.map(& &1.id)
  defp find(ctx, id), do: ctx |> Coach.insights() |> Enum.find(&(&1.id == id))

  defp pressure(state, awake, typical),
    do: %{state: state, awake_seconds: awake, typical_seconds: typical, upper_seconds: typical}

  test "a quiet day has nothing to flag" do
    assert Coach.insights(ctx()) == []
  end

  describe "time awake" do
    test "past the usual window is a watch, with C.R.I.E.S. for a newborn" do
      ctx = ctx(prediction: prediction(wake_pressure: pressure(:past, 6000, 4200)))

      assert %{tone: :watch, detail: detail} = find(ctx, "past-window")
      assert detail =~ "1h 40m"
      assert detail =~ "1h 10m"
      assert detail =~ "C.R.I.E.S."
    end

    test "no C.R.I.E.S. once past the newborn phase" do
      ctx =
        ctx(
          phase: @foundations,
          prediction: prediction(wake_pressure: pressure(:past, 8000, 6000))
        )

      refute find(ctx, "past-window").detail =~ "C.R.I.E.S."
    end

    test "an open window is a suggestion, mentioning their ready cue when known" do
      ctx =
        ctx(
          prediction: prediction(wake_pressure: pressure(:approaching, 3000, 3300)),
          habits: habits([], %{"ready" => %{n: 4, median_seconds: 3300}})
        )

      assert %{tone: :suggest, detail: detail} = find(ctx, "nap-window")
      assert detail =~ "Their ready cues usually show after about 55m"
      # Not repeated as its own card.
      refute "ready-window" in ids(ctx)
    end

    test "plenty of time left says nothing" do
      ctx = ctx(prediction: prediction(wake_pressure: pressure(:fresh, 600, 3600)))
      assert ids(ctx) == []
    end

    test "nothing about wake windows while a nap is running, even before the prediction knows" do
      now = t(13)
      napping = Day.build(child(), @date, [sleep(2, t(12, 59), nil)], now)

      ctx =
        ctx(
          now: now,
          today: napping,
          prediction: prediction(state: :awake, wake_pressure: pressure(:past, 9000, 3600))
        )

      refute "past-window" in ids(ctx)
    end

    test "nothing about wake windows while asleep" do
      ctx =
        ctx(prediction: prediction(state: :asleep, wake_pressure: pressure(:past, 9000, 3600)))

      refute "past-window" in ids(ctx)
    end
  end

  describe "a running nap" do
    defp napping(started, now),
      do: Day.build(child(), @date, [sleep(2, started, nil)], now)

    test "a newborn asleep more than 3 hours after the last feed, by day, may need one" do
      now = t(13)

      ctx =
        ctx(
          now: now,
          today: napping(t(11), now),
          last_feed_at: t(9, 30),
          prediction: prediction(state: :asleep)
        )

      assert %{tone: :suggest, detail: detail} = find(ctx, "feed-due")
      assert detail =~ "3h 30m"
    end

    test "not for a recent feed, an awake baby or the middle of the night" do
      now = t(13)
      napping = napping(t(11), now)

      recent =
        ctx(now: now, today: napping, last_feed_at: t(12), prediction: prediction(state: :asleep))

      refute "feed-due" in ids(recent)

      awake = ctx(now: now, last_feed_at: t(8))
      refute "feed-due" in ids(awake)

      night_now = at(@date, ~T[03:00:00])

      night =
        ctx(
          now: night_now,
          today: napping(at(@date, ~T[01:00:00]), night_now),
          last_feed_at: at(Date.add(@date, -1), ~T[22:00:00]),
          prediction: prediction(state: :asleep)
        )

      refute "feed-due" in ids(night)
    end

    test "past the newborn phase a nap over 2 hours should be woken" do
      now = t(14)

      ctx =
        ctx(
          phase: @foundations,
          now: now,
          today: napping(t(11, 30), now),
          prediction: prediction(state: :asleep)
        )

      assert %{tone: :suggest} = find(ctx, "long-nap")
      refute "long-nap" in ids(%{ctx | phase: @newborn})
    end
  end

  describe "the day's sleep" do
    test "bedtime pulled earlier by a short day is a suggestion" do
      bed = %{at: t(19, 15), label: "19:15", source: :history, shifted_by_seconds: 20 * 60}
      ctx = ctx(prediction: prediction(bedtime: bed))

      assert %{tone: :suggest, detail: detail} = find(ctx, "bedtime-earlier")
      assert detail =~ "19:15"
      assert detail =~ "20 minutes"
    end

    test "a tiny shift isn't worth mentioning" do
      bed = %{at: t(19, 15), label: "19:15", source: :history, shifted_by_seconds: 300}
      refute "bedtime-earlier" in ids(ctx(prediction: prediction(bedtime: bed)))
    end

    test "over 5 hours of daytime sleep is flagged after the newborn phase only" do
      now = t(17)
      long = [sleep(2, t(8), t(11)), sleep(3, t(12), t(15))]
      today = Day.build(child(), @date, long, now)

      assert %{tone: :watch} =
               find(ctx(phase: @foundations, today: today, now: now), "daytime-cap")

      refute "daytime-cap" in ids(ctx(phase: @newborn, today: today, now: now))
    end

    test "Foundations: a bedtime later than the sweet spot suggests shifting by 10–15 minutes" do
      bed = %{at: t(20, 45), label: "20:45", source: :history, shifted_by_seconds: 0}

      assert find(ctx(phase: @foundations, prediction: prediction(bedtime: bed)), "late-bedtime")
      refute "late-bedtime" in ids(ctx(phase: @newborn, prediction: prediction(bedtime: bed)))
    end
  end

  describe "cues and habits" do
    test "two or more overtired starts this week is a suggestion to settle earlier" do
      ctx = ctx(habits: habits(sleeps: 9, cued: 6, overtired: 2))
      assert %{tone: :suggest, detail: detail} = find(ctx, "overtired-pattern")
      assert detail =~ "2 of 6"
    end

    test "one overtired start is not a pattern" do
      refute "overtired-pattern" in ids(ctx(habits: habits(sleeps: 9, cued: 6, overtired: 1)))
    end

    test "their ready cue stands alone when nothing else mentions it" do
      ctx = ctx(habits: habits([], %{"ready" => %{n: 5, median_seconds: 3000}}))
      assert %{tone: :info, detail: detail} = find(ctx, "ready-window")
      assert detail =~ "50m"
    end

    test "mostly fed-to-sleep gets a reassuring note and a gentle idea" do
      ctx = ctx(habits: habits(sleeps: 10, measured: 8, fed_to_sleep: 7))
      assert %{tone: :info, detail: detail} = find(ctx, "feed-to-sleep")
      assert detail =~ "7 of 8"
      assert detail =~ "normal"

      refute "feed-to-sleep" in ids(ctx(habits: habits(measured: 8, fed_to_sleep: 3)))
      refute "feed-to-sleep" in ids(ctx(habits: habits(measured: 3, fed_to_sleep: 3)))
    end
  end

  describe "how sure the estimates are" do
    test "age-based estimates are called out, by name" do
      ctx = ctx(prediction: prediction(next_nap: %{source: :age_prior}))
      assert %{tone: :info, detail: detail} = find(ctx, "age-estimates")
      assert detail =~ "Astrid"
    end

    test "history-based estimates aren't" do
      refute "age-estimates" in ids(ctx(prediction: prediction(next_nap: %{source: :history})))
    end

    test "a suspected nap transition says the times are wider" do
      assert find(ctx(prediction: prediction(transition?: true)), "transition")
    end
  end

  test "most pressing first, and capped" do
    ctx =
      ctx(
        prediction:
          prediction(
            wake_pressure: pressure(:past, 6000, 4200),
            bedtime: %{at: t(19), label: "19:00", source: :age_prior, shifted_by_seconds: 1200},
            next_nap: %{source: :age_prior},
            transition?: true
          ),
        habits:
          habits([sleeps: 10, cued: 6, overtired: 3, measured: 8, fed_to_sleep: 8], %{
            "ready" => %{n: 4, median_seconds: 3000}
          })
      )

    insights = Coach.insights(ctx)

    assert length(insights) <= 6
    assert hd(insights).tone == :watch
    tones = Enum.map(insights, & &1.tone)
    assert tones == Enum.sort_by(tones, &Map.fetch!(%{watch: 0, suggest: 1, info: 2}, &1))
  end
end
