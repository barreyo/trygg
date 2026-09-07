defmodule Trygg.Reports.RhythmTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias Trygg.Reports.Day
  alias Trygg.Reports.Rhythm

  defp child do
    %Child{
      timezone: "Etc/UTC",
      day_start: ~T[08:00:00],
      night_start: ~T[20:00:00],
      birth_date: ~D[2026-01-01]
    }
  end

  defp sleep(id, start, finish) do
    %Entry{id: id, type: :sleep, started_at: start, ended_at: finish, data: %{}}
  end

  defp datetime(%Date{} = date, %Time{} = time), do: DateTime.new!(date, time, "Etc/UTC")

  # A day with a fixed morning wake, two naps and a bedtime, built as a `%Day{}`.
  defp day(date, opts) do
    wake = Keyword.get(opts, :wake, ~T[07:00:00])
    bed = Keyword.get(opts, :bed, ~T[19:30:00])
    naps = Keyword.get(opts, :naps, [{~T[09:30:00], ~T[10:30:00]}, {~T[13:00:00], ~T[14:30:00]}])
    now = Keyword.get(opts, :now, datetime(Date.add(date, 1), ~T[12:00:00]))
    base = date.day * 100
    prev = Date.add(date, -1)

    nap_entries =
      naps
      |> Enum.with_index(1)
      |> Enum.map(fn {{s, e}, i} -> sleep(base + i, datetime(date, s), datetime(date, e)) end)

    entries =
      [sleep(base, datetime(prev, ~T[19:30:00]), datetime(date, wake))] ++
        nap_entries ++
        [sleep(base + 50, datetime(date, bed), datetime(Date.add(date, 1), ~T[07:00:00]))]

    Day.build(child(), date, entries, now)
  end

  defp dates(from, count), do: Enum.map(0..(count - 1), &Date.add(from, &1))

  describe "summarize/4" do
    test "falls back to a plain default day when history is thin" do
      today = ~D[2026-03-10]
      now = datetime(today, ~T[10:30:00])
      days = [Day.build(child(), today, [], now)]

      rhythm = Rhythm.summarize(child(), days, List.last(days), now)

      refute rhythm.ready?
      assert rhythm.wake_minutes == 7 * 60
      assert rhythm.bed_minutes == 19 * 60 + 30
      assert rhythm.naps == []
      assert rhythm.today == []
      assert_in_delta rhythm.now_minutes, 10 * 60 + 30, 0.5
    end

    test "derives typical wake, bedtime and nap windows from consistent days" do
      start = ~D[2026-03-01]
      today = ~D[2026-03-08]
      built = Enum.map(dates(start, 8), &day(&1, now: datetime(today, ~T[12:00:00])))
      today_day = List.last(built)

      rhythm = Rhythm.summarize(child(), built, today_day, datetime(today, ~T[12:00:00]))

      assert rhythm.ready?
      assert rhythm.wake_minutes == 7 * 60
      assert rhythm.bed_minutes == 19 * 60 + 30

      assert [nap1, nap2] = rhythm.naps
      assert nap1.ordinal == 1
      assert nap1.start_minutes == 9 * 60 + 30
      assert_in_delta nap1.end_minutes, 10 * 60 + 30, 0.1
      assert nap2.ordinal == 2
      assert nap2.start_minutes == 13 * 60
    end

    test "pushes a past-midnight bedtime beyond 1440 so it sorts after wake" do
      start = ~D[2026-03-01]
      today = ~D[2026-03-08]

      built =
        Enum.map(dates(start, 8), fn d ->
          day(d, bed: ~T[00:20:00], now: datetime(today, ~T[12:00:00]))
        end)

      rhythm = Rhythm.summarize(child(), built, List.last(built), datetime(today, ~T[12:00:00]))

      assert rhythm.bed_minutes == 24 * 60 + 20
      assert rhythm.bed_minutes > rhythm.wake_minutes
    end

    test "excludes today from the typical figures but reports its sleep so far" do
      start = ~D[2026-03-01]
      today = ~D[2026-03-08]
      now = datetime(today, ~T[10:00:00])

      history = Enum.map(dates(start, 7), &day(&1, now: now))

      # Today: woke 07:00, one finished nap 08:30–09:15, still awake at 10:00.
      today_day =
        Day.build(
          child(),
          today,
          [
            sleep(1, datetime(Date.add(today, -1), ~T[19:30:00]), datetime(today, ~T[07:00:00])),
            sleep(2, datetime(today, ~T[08:30:00]), datetime(today, ~T[09:15:00]))
          ],
          now
        )

      rhythm = Rhythm.summarize(child(), history ++ [today_day], today_day, now)

      # Typical naps still come only from the 7 complete history days.
      assert length(rhythm.naps) == 2

      # Today's segments: the overnight tail (00:00–07:00) plus the finished nap.
      assert [_overnight, nap] = rhythm.today
      assert_in_delta nap.start_minutes, 8 * 60 + 30, 0.1
      assert_in_delta nap.end_minutes, 9 * 60 + 15, 0.1
      refute nap.running?
    end

    test "flags a running nap in today's segments" do
      today = ~D[2026-03-10]
      now = datetime(today, ~T[13:30:00])

      today_day =
        Day.build(
          child(),
          today,
          [
            sleep(1, datetime(Date.add(today, -1), ~T[19:30:00]), datetime(today, ~T[07:00:00])),
            sleep(2, datetime(today, ~T[13:00:00]), nil)
          ],
          now
        )

      rhythm = Rhythm.summarize(child(), [today_day], today_day, now)

      assert Enum.any?(rhythm.today, & &1.running?)
    end
  end
end
