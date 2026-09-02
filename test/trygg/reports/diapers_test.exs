defmodule Trygg.Reports.DiapersTest do
  use ExUnit.Case, async: true

  import Trygg.ReportDays

  alias Trygg.Reports.Diapers

  @today ~D[2026-03-10]

  # Seven wet diapers a day at 07, 09, 11, 13, 15, 17, 19 on every prior day;
  # today gets `today_count` of them, then `now`.
  defp days(today_count, now, opts \\ []) do
    n = Keyword.get(opts, :days, 8)
    dates = dates_ending(@today, n)

    entries =
      Enum.flat_map(dates, fn date ->
        count = if date == @today, do: today_count, else: Keyword.get(opts, :count, 7)
        diaper_day(date, count: count) ++ Keyword.get(opts, :extra, fn _ -> [] end).(date)
      end)

    build_days(child(Keyword.get(opts, :child, %{})), dates, entries, now)
  end

  test "counts wet and dirty per day and builds a baseline" do
    now = at(@today, ~T[12:00:00])
    summary = Diapers.summarize(child(), days(3, now), now)

    assert summary.ready?
    assert summary.baseline.wet.median == 7.0
    assert summary.baseline.dirty.median == 0.0
    assert List.last(summary.per_day).wet == 3
    assert summary.min_wet == 6
    assert summary.flags == []
  end

  test "mixed diapers count as both wet and dirty" do
    now = at(@today, ~T[12:00:00])

    entries = [
      diaper(1, at(@today, ~T[09:00:00]), "mixed"),
      diaper(2, at(@today, ~T[10:00:00]), "poo")
    ]

    summary = Diapers.summarize(child(), build_days(child(), [@today], entries, now), now)

    assert %{wet: 1, dirty: 2} = List.last(summary.per_day)
  end

  test "today's pace is compared with prior days at the same clock time" do
    now = at(@today, ~T[16:30:00])
    # By 16:30 prior days have 5 wet (07, 09, 11, 13, 15); today has only 1.
    summary = Diapers.summarize(child(), days(1, now), now)

    assert summary.today.expected_wet_by_now == 5.0
    assert summary.today.wet == 1
    assert :low_wet_pace in summary.flags
  end

  test "no wet diaper for six hours is flagged only when someone is still logging" do
    now = at(@today, ~T[16:30:00])
    # Last wet at 07:00 today, a feed at 15:00 shows the family is logging.
    extra = fn date -> if date == @today, do: [feed(9, at(date, ~T[15:00:00]))], else: [] end
    summary = Diapers.summarize(child(), days(1, now, extra: extra), now)

    assert :no_wet_6h in summary.flags
    assert summary.dry_seconds == 9 * 3600 + 30 * 60

    quiet = Diapers.summarize(child(), days(1, now), now)
    refute :no_wet_6h in quiet.flags
  end

  test "a full day under the floor and under baseline is flagged" do
    now = at(@today, ~T[09:00:00])
    dates = dates_ending(@today, 8)
    yesterday = Date.add(@today, -1)

    entries =
      Enum.flat_map(dates, fn date ->
        cond do
          date == @today -> [diaper(1, at(date, ~T[08:00:00]))]
          date == yesterday -> diaper_day(date, count: 3)
          true -> diaper_day(date, count: 7)
        end
      end)

    summary = Diapers.summarize(child(), build_days(child(), dates, entries, now), now)
    assert :low_wet_day in summary.flags
    assert summary.yesterday.wet == 3
  end

  test "newborn day-of-life ramp lowers the floor" do
    now = at(@today, ~T[09:00:00])
    child = child(%{birth_date: Date.add(@today, -2)})

    summary =
      Diapers.summarize(child, days(1, now, child: %{birth_date: Date.add(@today, -2)}), now)

    assert summary.min_wet == 3
    refute :low_wet_day in summary.flags
  end
end
