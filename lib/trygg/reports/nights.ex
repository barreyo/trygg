defmodule Trygg.Reports.Nights do
  @moduledoc """
  How the last several nights went: when they started and ended, how long they
  slept, how many times they woke, the longest unbroken sleep and the longest
  stretch between feeds.

  The longest stretch between feeds is the guides' "best baseline" ground: how
  long a baby recently and repeatedly goes without a night feed is where
  stretching them begins, from about 13 weeks. Nothing here changes feeding
  advice; it's the history that advice will need.

  Pure: takes a child, their `%Day{}`s (oldest first, with the day after each
  night so its morning wake is known) and the entries (sleeps, bottles and
  breastfeeding) they were built from.
  """

  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias Trygg.Reports.Day

  @nights 7
  # Feeds this close to bedtime or the morning wake belong to the bedtime
  # routine or the morning, not the night.
  @feed_margin_seconds 15 * 60
  # How far around the night a feed still counts toward the stretch between feeds.
  @feed_window_seconds 3 * 3600
  # The recent-vs-earlier comparison needs this many nights on each side.
  @trend_nights 3

  @doc "How many nights `summarize/3` covers at most."
  def count, do: @nights

  @doc """
  `%{nights, last, best_baseline_seconds, best_sleep_seconds, trend_seconds}`.

  `nights` is the finished nights, newest first, each

      %{date, bedtime, wake, asleep_seconds, wakings, longest_sleep_seconds,
        feeds, longest_feed_gap_seconds}

  where `date` is the evening the night began. `best_baseline_seconds` is the
  longest stretch between feeds reached on at least two of those nights (the
  second longest), `trend_seconds` how much the last 3 nights' longest sleep
  beats the 3 before them (`nil` without six nights).
  """
  def summarize(%Child{}, days, entries) when is_list(days) and is_list(entries) do
    sleeps = Enum.filter(entries, &(&1.type == :sleep))
    feeds = for e <- entries, e.type in [:feeding, :breastfeeding], do: e.started_at

    nights =
      days
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [evening, morning] -> night(evening, morning, sleeps, feeds) end)
      |> Enum.take(-@nights)
      |> Enum.reverse()

    %{
      nights: nights,
      last: List.first(nights),
      best_baseline_seconds: best_baseline(nights),
      best_sleep_seconds:
        nights |> Enum.map(& &1.longest_sleep_seconds) |> Enum.max(fn -> nil end),
      trend_seconds: trend(nights)
    }
  end

  defp night(
         %Day{bedtime: %DateTime{} = bed} = evening,
         %Day{morning_wake: %DateTime{} = wake},
         sleeps,
         feeds
       ) do
    if DateTime.compare(wake, bed) == :gt do
      [
        %{
          date: evening.date,
          bedtime: bed,
          wake: wake,
          asleep_seconds: asleep_seconds(sleeps, bed, wake),
          wakings: length(evening.night_wakings || []),
          longest_sleep_seconds: longest_sleep(bed, wake, evening.night_wakings || []),
          feeds: night_feeds(feeds, bed, wake),
          longest_feed_gap_seconds: longest_feed_gap(feeds, bed, wake)
        }
      ]
    else
      []
    end
  end

  defp night(_evening, _morning, _sleeps, _feeds), do: []

  defp asleep_seconds(sleeps, bed, wake) do
    Enum.reduce(sleeps, 0, fn %Entry{} = sleep, total ->
      start = later(sleep.started_at, bed)
      finish = earlier(sleep.ended_at || wake, wake)
      total + max(DateTime.diff(finish, start, :second), 0)
    end)
  end

  # The longest run between wakings (or from bedtime / to the morning wake).
  defp longest_sleep(bed, wake, wakings) do
    {stretches, last_end} =
      wakings
      |> Enum.sort_by(& &1.start, DateTime)
      |> Enum.reduce({[], bed}, fn waking, {acc, from} ->
        {[DateTime.diff(waking.start, from, :second) | acc], later(waking.end, from)}
      end)

    [DateTime.diff(wake, last_end, :second) | stretches]
    |> Enum.max()
    |> max(0)
  end

  defp night_feeds(feeds, bed, wake) do
    from = DateTime.add(bed, @feed_margin_seconds, :second)
    to = DateTime.add(wake, -@feed_margin_seconds, :second)
    Enum.count(feeds, &(DateTime.compare(&1, from) != :lt and DateTime.compare(&1, to) != :gt))
  end

  # Longest gap between consecutive feeds, counting the last feed before
  # bedtime and the first after the morning wake, so a night with no feed in it
  # reads as the long stretch it was.
  defp longest_feed_gap(feeds, bed, wake) do
    from = DateTime.add(bed, -@feed_window_seconds, :second)
    to = DateTime.add(wake, @feed_window_seconds, :second)

    around =
      feeds
      |> Enum.filter(&(DateTime.compare(&1, from) != :lt and DateTime.compare(&1, to) != :gt))
      |> Enum.sort(DateTime)

    around
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [a, b] ->
      DateTime.compare(a, wake) == :lt and DateTime.compare(b, bed) == :gt
    end)
    |> Enum.map(fn [a, b] -> DateTime.diff(b, a, :second) end)
    |> Enum.max(fn -> nil end)
  end

  # Reached on at least two nights: the second longest.
  defp best_baseline(nights) do
    case nights
         |> Enum.map(& &1.longest_feed_gap_seconds)
         |> Enum.reject(&is_nil/1)
         |> Enum.sort(:desc) do
      [_, second | _] -> second
      _ -> nil
    end
  end

  defp trend(nights) when length(nights) >= 2 * @trend_nights do
    {recent, earlier} =
      nights |> Enum.map(& &1.longest_sleep_seconds) |> Enum.split(@trend_nights)

    earlier = Enum.take(earlier, @trend_nights)
    round(mean(recent) - mean(earlier))
  end

  defp trend(_nights), do: nil

  defp mean(list), do: Enum.sum(list) / length(list)
  defp later(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
  defp earlier(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)
end
