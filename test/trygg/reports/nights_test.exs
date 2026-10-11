defmodule Trygg.Reports.NightsTest do
  use ExUnit.Case, async: true

  import Trygg.ReportDays

  alias Trygg.Reports.Day
  alias Trygg.Reports.Nights

  @d0 ~D[2026-10-01]

  defp t(date, hour, minute \\ 0), do: at(date, Time.new!(hour, minute, 0))

  defp build(entries, dates, now) do
    days = Enum.map(dates, &Day.build(child(), &1, entries, now))
    Nights.summarize(child(), days, entries)
  end

  defp bottle(id, at), do: feed(id, at)

  describe "one night" do
    test "a clean night: bedtime to morning, no wakings, one long stretch between feeds" do
      d0 = @d0
      d1 = Date.add(d0, 1)

      entries = [
        sleep(1, t(d0, 20), t(d1, 7)),
        bottle(2, t(d0, 19, 30)),
        bottle(3, t(d1, 7, 10))
      ]

      assert %{nights: [night], last: night} = build(entries, [d0, d1], t(d1, 12))

      assert night.date == d0
      assert night.bedtime == t(d0, 20)
      assert night.wake == t(d1, 7)
      assert night.asleep_seconds == 11 * 3600
      assert night.wakings == 0
      assert night.longest_sleep_seconds == 11 * 3600
      assert night.feeds == 0
      # 19:30 to 07:10.
      assert night.longest_feed_gap_seconds == 11 * 3600 + 40 * 60
    end

    test "a waking splits the sleep; the longest stretch is the better half" do
      d0 = @d0
      d1 = Date.add(d0, 1)

      entries = [
        sleep(1, t(d0, 20), t(d1, 1)),
        sleep(2, t(d1, 1, 30), t(d1, 7)),
        bottle(3, t(d0, 19, 30)),
        bottle(4, t(d1, 1, 10)),
        bottle(5, t(d1, 7, 10))
      ]

      assert %{last: night} = build(entries, [d0, d1], t(d1, 12))

      assert night.wakings == 1
      assert night.longest_sleep_seconds == 5 * 3600 + 30 * 60
      assert night.asleep_seconds == 10 * 3600 + 30 * 60
      assert night.feeds == 1
      # 19:30 → 01:10 is 5h40, 01:10 → 07:10 is 6h.
      assert night.longest_feed_gap_seconds == 6 * 3600
    end

    test "feeds right at bedtime or the morning wake aren't night feeds" do
      d0 = @d0
      d1 = Date.add(d0, 1)

      entries = [
        sleep(1, t(d0, 20), t(d1, 7)),
        bottle(2, t(d0, 20, 5)),
        bottle(3, t(d1, 6, 55))
      ]

      assert %{last: %{feeds: 0}} = build(entries, [d0, d1], t(d1, 12))
    end

    test "no feeds logged means no stretch between feeds" do
      d0 = @d0
      d1 = Date.add(d0, 1)

      assert %{last: %{longest_feed_gap_seconds: nil}} =
               build([sleep(1, t(d0, 20), t(d1, 7))], [d0, d1], t(d1, 12))
    end
  end

  describe "several nights" do
    # Night i: asleep 20:00 to 20:00 + `first` hours, awake 30 min, asleep until
    # 07:00. Longest sleep is the larger of `first` and 10.5 - `first`.
    defp night_entries(date, first_hours, id) do
      next = Date.add(date, 1)
      stop = DateTime.add(t(date, 20), first_hours * 3600, :second)

      [
        sleep(id, t(date, 20), stop),
        sleep(id + 1, DateTime.add(stop, 1800, :second), t(next, 7))
      ]
    end

    defp week(firsts) do
      dates = Enum.map(0..length(firsts), &Date.add(@d0, &1))

      entries =
        firsts
        |> Enum.with_index()
        |> Enum.flat_map(fn {first, i} -> night_entries(Date.add(@d0, i), first, i * 10 + 1) end)

      build(entries, dates, t(List.last(dates), 12))
    end

    test "lists finished nights, newest first, up to seven" do
      result = week([5, 5, 5, 5, 4, 4, 3, 3])

      assert length(result.nights) == 7
      assert hd(result.nights).date == Date.add(@d0, 7)
      assert List.last(result.nights).date == Date.add(@d0, 1)
    end

    test "trend compares the last three nights' longest sleep with the three before" do
      # Oldest to newest: first = 5 (5.5h longest) ×3, then 4, 4, 3 (6.5h, 6.5h, 7.5h).
      result = week([5, 5, 5, 5, 4, 4, 3])

      assert length(result.nights) == 7
      assert result.best_sleep_seconds == round(7.5 * 3600)
      # mean(6.5, 6.5, 7.5) - mean(5.5, 5.5, 5.5) = 1h20m.
      assert result.trend_seconds == 80 * 60
    end

    test "no trend without six nights" do
      assert week([5, 5, 4, 4]).trend_seconds == nil
    end

    test "best baseline is the longest stretch reached on at least two nights" do
      dates = Enum.map(0..3, &Date.add(@d0, &1))

      # Feeds at 19:30, a night feed, and 07:30: longest gaps 7h, 6h30, 8h.
      night_feeds = [{0, {0, 30}}, {1, {2, 0}}, {2, {3, 30}}]

      entries =
        Enum.flat_map(night_feeds, fn {i, {h, m}} ->
          d = Date.add(@d0, i)
          n = Date.add(d, 1)

          [
            sleep(i * 10 + 1, t(d, 20), t(n, 7)),
            bottle(i * 10 + 2, t(d, 19, 30)),
            bottle(i * 10 + 3, t(n, h, m)),
            bottle(i * 10 + 4, t(n, 7, 30))
          ]
        end)

      result = build(entries, dates, t(List.last(dates), 12))

      assert result.nights |> Enum.map(& &1.longest_feed_gap_seconds) |> Enum.sort() ==
               [23_400, 25_200, 28_800]

      # 8h, 7h, 6h30: reached twice means 7h.
      assert result.best_baseline_seconds == 7 * 3600
    end

    test "one night isn't 'repeated'" do
      d0 = @d0
      d1 = Date.add(d0, 1)

      entries = [
        sleep(1, t(d0, 20), t(d1, 7)),
        bottle(2, t(d0, 19, 30)),
        bottle(3, t(d1, 7, 10))
      ]

      assert build(entries, [d0, d1], t(d1, 12)).best_baseline_seconds == nil
    end
  end

  test "no nights without a finished night" do
    assert %{nights: [], last: nil, best_baseline_seconds: nil, trend_seconds: nil} =
             build([], [@d0, Date.add(@d0, 1)], t(Date.add(@d0, 1), 12))
  end
end
