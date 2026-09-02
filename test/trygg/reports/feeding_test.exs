defmodule Trygg.Reports.FeedingTest do
  use ExUnit.Case, async: true

  import Trygg.ReportDays

  alias Trygg.Reports.Feeding

  @today ~D[2026-03-10]

  # Full days of bottles at 08/12/16/20, with today logged only up to 12:00
  # (now is 12:30). Day gaps are 4h; the 20:00 → 08:00 gap is a 12h night one.
  defp regular_days(n, opts) do
    dates = dates_ending(@today, n)

    entries =
      Enum.flat_map(dates, fn date ->
        count = if date == @today, do: 2, else: 4

        feed_day(
          date,
          Keyword.merge([first: ~T[08:00:00], every_hours: 4, count: count], opts)
        )
      end)

    now = Keyword.get(opts, :now, at(@today, ~T[12:30:00]))
    build_days(child(), dates, entries, now)
  end

  test "not ready with too few intervals" do
    days =
      build_days(child(), [@today], [feed(1, at(@today, ~T[08:00:00]))], at(@today, ~T[10:00:00]))

    summary = Feeding.summarize(child(), days, at(@today, ~T[10:00:00]))

    refute summary.ready?
    assert summary.intervals.day.median == nil
    assert summary.next_feed == nil
    assert summary.last_feed_at == at(@today, ~T[08:00:00])
  end

  test "splits intervals by day and night and predicts the next feed" do
    now = at(@today, ~T[12:30:00])
    days = regular_days(4, now: now)
    summary = Feeding.summarize(child(), days, now)

    assert summary.ready?
    assert summary.intervals.day.median == 4 * 3600.0
    assert summary.intervals.night.median == 12 * 3600.0
    assert summary.count.median == 4.0
    assert summary.ml.median == 360.0

    assert %{label: "16:00", period: :day, in_seconds: in_seconds} = summary.next_feed
    assert in_seconds == 3 * 3600 + 30 * 60
    assert summary.next_feed.range.label =~ "16:00"
  end

  test "reports volume per feeding episode" do
    now = at(@today, ~T[12:30:00])
    summary = Feeding.summarize(child(), regular_days(4, now: now, ml: 120), now)

    assert summary.per_feed.median == 120.0
    assert summary.per_feed.n == 14
  end

  test "typical-for-age pattern is labelled as an age prior and absent without a birth date" do
    now = at(@today, ~T[12:30:00])
    days = regular_days(4, now: now)

    assert Feeding.summarize(child(), days, now).typical == nil

    child = child(%{birth_date: Date.add(@today, -60)})

    assert %{feeds_per_day: {5, 6}, ml_per_feed: {150, 180}, source: :age_prior} =
             Feeding.summarize(child, days, now).typical
  end

  test "feeds within 30 minutes count as one episode" do
    now = at(@today, ~T[13:00:00])
    dates = dates_ending(@today, 3)

    entries =
      Enum.flat_map(dates, fn date ->
        feed_day(date, count: 4, every_hours: 3) ++
          [feed(date.day * 1000 + 99, at(date, ~T[06:10:00]), 20)]
      end)

    summary = Feeding.summarize(child(), build_days(child(), dates, entries, now), now)
    assert summary.intervals.day.median == 3 * 3600.0
  end

  test "flags a cluster when three feeds land inside two hours" do
    now = at(@today, ~T[19:30:00])

    entries = [
      feed(1, at(@today, ~T[17:45:00])),
      feed(2, at(@today, ~T[18:30:00])),
      feed(3, at(@today, ~T[19:10:00]))
    ]

    summary = Feeding.summarize(child(), build_days(child(), [@today], entries, now), now)
    assert summary.cluster.active?
    assert summary.cluster.count == 3
  end

  test "intake guide compares a 3-day average with the ml/kg band for age" do
    now = at(@today, ~T[12:30:00])
    child = child(%{birth_date: Date.add(@today, -40)})
    weight = %{grams: 4000.0, date: @today}

    # 4 × 90 ml = 360 ml/day on 4 kg → 90 ml/kg, well under the 150–180 band
    days = regular_days(4, now: now)
    summary = Feeding.summarize(child, days, now, weight: weight)

    assert %{status: :below, avg_days: 3, avg_ml: 360.0} = summary.intake
    assert_in_delta summary.intake.ml_per_kg, 90.0, 0.01

    # 4 × 170 ml = 680 → 170 ml/kg, within
    days = regular_days(4, now: now, ml: 170)
    assert %{status: :within} = Feeding.summarize(child, days, now, weight: weight).intake
  end

  test "intake guide is skipped without a fresh weight or a known age" do
    now = at(@today, ~T[12:30:00])
    days = regular_days(4, now: now)

    assert Feeding.summarize(child(), days, now, weight: %{grams: 4000.0, date: @today}).intake ==
             nil

    stale = %{grams: 4000.0, date: Date.add(@today, -30)}
    child = child(%{birth_date: Date.add(@today, -40)})
    assert Feeding.summarize(child, days, now, weight: stale).intake == nil
  end
end
