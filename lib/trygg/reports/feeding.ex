defmodule Trygg.Reports.Feeding do
  @moduledoc """
  Bottle-feeding rhythm over a window of `%Trygg.Reports.Day{}`: intervals by
  day and night, daily volume, volume per feed, a next-feed estimate, a
  cluster-feeding note, an informational intake-per-kilo guide when a recent
  weight exists, the "typical for age" feeds/day and ml/feed from
  `Trygg.Reports.Norms` as labelled population context, and how long a feed
  takes — overall, per day and its trend over the window.

  Feeds are logged when the bottle is finished, so feed length is inferred
  from a diaper change logged just before it (see `Trygg.Reports.FeedTiming`).

  Pure: takes the child, the days (oldest first, today last), `now`, and an
  optional recent weight. Feeds logged within `@episode_gap` of each other are
  treated as one feeding episode, so a topped-up bottle does not create a
  five-minute "interval".
  """

  alias Trygg.Families.Child
  alias Trygg.Reports.Day
  alias Trygg.Reports.FeedTiming
  alias Trygg.Reports.Norms
  alias Trygg.Reports.Stats

  @min_intervals 3
  @episode_gap 30 * 60
  # Gaps longer than this are missing logs, not a real interval.
  @max_interval 12 * 3600
  @cluster_window 2 * 3600
  @cluster_min_feeds 3
  @weight_max_age_days 14
  @intake_days 3
  @intake_tolerance 0.15
  # Days with at least one timed feed needed before fitting a trend line.
  @min_trend_days 4

  @doc """
  Summarizes feeding over `days`.

  Options: `:weight` — `%{grams: number, date: Date.t()}` for the intake guide.
  """
  def summarize(%Child{} = child, days, %DateTime{} = now, opts \\ []) when is_list(days) do
    now = DateTime.truncate(now, :second)
    feeds = days |> Enum.flat_map(& &1.feeds) |> Enum.sort_by(& &1.at, DateTime)
    episodes = episodes(feeds)
    intervals = intervals(child, episodes)
    ready? = length(intervals) >= @min_intervals

    timed = feed_durations(feeds, days)
    per_day = Enum.map(days, &day_row(&1, timed))
    feed_days = Enum.filter(per_day, &(&1.count > 0))
    last = List.last(feeds)
    today = today_date(child, days)

    by_period = %{
      day: interval_sample(intervals, :day, ready?),
      night: interval_sample(intervals, :night, ready?),
      overall: interval_sample(intervals, nil, ready?)
    }

    per_feed_ml = episodes |> Enum.map(& &1.ml) |> Enum.filter(&(&1 > 0))
    durations = Map.values(timed)

    %{
      ready?: ready?,
      min_intervals: @min_intervals,
      per_day: per_day,
      count: Stats.sample(Enum.map(feed_days, & &1.count), feed_days != []),
      ml: Stats.sample(Enum.map(feed_days, & &1.ml), feed_days != []),
      per_feed: Stats.sample(per_feed_ml, length(per_feed_ml) >= @min_intervals),
      duration: duration(durations, per_day),
      intervals: by_period,
      last_feed_at: last && last.at,
      next_feed: next_feed(child, last, by_period, now),
      cluster: cluster(feeds, now),
      intake: intake(child, today, per_day, Keyword.get(opts, :weight)),
      typical: typical(child, today)
    }
  end

  defp today_date(child, days) do
    case List.last(days) do
      %Day{date: d} -> d
      _ -> Child.local_today(child)
    end
  end

  # Population "typical for age" pattern, labelled as such so it is never
  # mistaken for the baby's own rhythm.
  defp typical(child, today) do
    case Norms.typical_feeds(Norms.corrected_age_days(child, today)) do
      nil -> nil
      typical -> Map.put(typical, :source, :age_prior)
    end
  end

  ## Episodes & intervals -------------------------------------------------

  defp episodes(feeds) do
    feeds
    |> Enum.reduce([], fn feed, acc ->
      case acc do
        [%{last_at: last_at} = current | rest]
        when is_struct(last_at, DateTime) ->
          if DateTime.diff(feed.at, last_at, :second) <= @episode_gap do
            [%{current | last_at: feed.at, ml: current.ml + ml(feed)} | rest]
          else
            [new_episode(feed) | acc]
          end

        _ ->
          [new_episode(feed) | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp new_episode(feed), do: %{at: feed.at, last_at: feed.at, ml: ml(feed)}

  defp intervals(child, episodes) do
    episodes
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [a, b] ->
      seconds = DateTime.diff(b.at, a.at, :second)

      if seconds > 0 and seconds <= @max_interval do
        [%{seconds: seconds, period: if(Child.daytime?(child, a.at), do: :day, else: :night)}]
      else
        []
      end
    end)
  end

  defp interval_sample(intervals, period, ready?) do
    seconds =
      intervals
      |> Enum.filter(&(is_nil(period) or &1.period == period))
      |> Enum.map(& &1.seconds)

    ready? = ready? and length(seconds) >= @min_intervals

    seconds
    |> Stats.sample(ready?)
    |> Map.put(:quartiles, if(ready?, do: Stats.quartiles(seconds)))
  end

  defp day_row(%Day{} = day, timed) do
    durations = day.feeds |> Enum.map(&timed[&1.id]) |> Enum.reject(&is_nil/1)

    %{
      date: day.date,
      count: length(day.feeds),
      ml: day.feeds |> Enum.map(&ml/1) |> Enum.sum(),
      duration: Stats.mean(durations),
      timed: length(durations),
      complete?: not day.now?
    }
  end

  defp ml(%{data: %{"amount_ml" => n}}) when is_number(n), do: n
  defp ml(_), do: 0

  ## Feed length ----------------------------------------------------------

  defp feed_durations(feeds, days),
    do: FeedTiming.durations(feeds, Enum.flat_map(days, & &1.diapers))

  defp duration(durations, per_day) do
    ready? = length(durations) >= @min_intervals

    durations
    |> Stats.sample(ready?)
    |> Map.merge(%{
      per_day: Enum.map(per_day, &%{date: &1.date, seconds: &1.duration, n: &1.timed}),
      trend: if(ready?, do: duration_trend(per_day))
    })
  end

  # Least-squares slope of the daily averages against the calendar day, so
  # days without a timed feed leave a gap instead of squashing the line.
  defp duration_trend(per_day) do
    points =
      per_day
      |> Enum.with_index()
      |> Enum.filter(fn {row, _i} -> is_number(row.duration) end)

    if length(points) >= @min_trend_days do
      xs = Enum.map(points, fn {_row, i} -> i end)
      ys = Enum.map(points, fn {row, _i} -> row.duration end)
      per_week = Stats.slope(xs, ys) * 7

      %{
        seconds_per_week: per_week,
        direction: trend_direction(per_week),
        days: length(points)
      }
    end
  end

  defp trend_direction(per_week) when abs(per_week) < 60, do: :steady
  defp trend_direction(per_week) when per_week > 0, do: :longer
  defp trend_direction(_per_week), do: :shorter

  ## Next feed --------------------------------------------------------------

  defp next_feed(_child, nil, _by_period, _now), do: nil

  defp next_feed(child, last, by_period, now) do
    period = if Child.daytime?(child, last.at), do: :day, else: :night

    case pick_interval(by_period, period) do
      nil ->
        nil

      {sample, used_period} ->
        at = DateTime.add(last.at, round(sample.median), :second)

        %{
          at: at,
          label: Child.local_clock(child, at),
          in_seconds: DateTime.diff(at, now, :second),
          period: used_period,
          n: sample.n,
          typical_seconds: sample.median,
          range: sample.quartiles && range_labels(child, last.at, sample.quartiles)
        }
    end
  end

  defp pick_interval(by_period, period) do
    cond do
      by_period[period].median -> {by_period[period], period}
      by_period.overall.median -> {by_period.overall, :overall}
      true -> nil
    end
  end

  defp range_labels(child, from_at, {lo, hi}) do
    from = DateTime.add(from_at, round(lo), :second)
    to = DateTime.add(from_at, round(hi), :second)

    %{
      from: from,
      to: to,
      label: "#{Child.local_clock(child, from)}–#{Child.local_clock(child, to)}"
    }
  end

  ## Cluster feeding -------------------------------------------------------

  defp cluster(feeds, now) do
    since = DateTime.add(now, -@cluster_window, :second)
    recent = Enum.filter(feeds, &(DateTime.compare(&1.at, since) != :lt))

    if length(recent) >= @cluster_min_feeds do
      %{
        active?: true,
        count: length(recent),
        since: hd(recent).at,
        window_seconds: @cluster_window
      }
    else
      %{active?: false, count: length(recent), since: nil, window_seconds: @cluster_window}
    end
  end

  ## Intake guide ----------------------------------------------------------

  defp intake(_child, _today, _per_day, nil), do: nil

  defp intake(%Child{} = child, today, per_day, %{grams: grams, date: %Date{} = weight_date})
       when is_number(grams) and grams > 0 do
    guide = Norms.intake_ml_per_kg(Norms.corrected_age_days(child, today))
    weight_fresh? = Date.diff(today, weight_date) <= @weight_max_age_days

    complete =
      per_day
      |> Enum.filter(&(&1.complete? and &1.count > 0))
      |> Enum.take(-@intake_days)

    if guide && weight_fresh? && complete != [] do
      {lo, hi} = guide
      kg = grams / 1000.0
      avg = Stats.mean(Enum.map(complete, & &1.ml))
      today_ml = per_day |> List.last() |> then(&(&1 && &1.ml)) || 0
      lo_ml = lo * kg
      hi_ml = hi * kg

      status =
        cond do
          avg < lo_ml * (1 - @intake_tolerance) -> :below
          avg > hi_ml * (1 + @intake_tolerance) -> :above
          true -> :within
        end

      %{
        avg_ml: avg,
        avg_days: length(complete),
        today_ml: today_ml,
        ml_per_kg: avg / kg,
        guide_per_kg: guide,
        guide_ml: {lo_ml, hi_ml},
        weight_g: grams,
        weight_date: weight_date,
        status: status
      }
    end
  end

  defp intake(_child, _today, _per_day, _weight), do: nil
end
