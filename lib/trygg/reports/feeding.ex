defmodule Trygg.Reports.Feeding do
  @moduledoc """
  Bottle-feeding rhythm over a window of `%Trygg.Reports.Day{}`: intervals by
  day and night, daily volume, a next-feed estimate, a cluster-feeding note,
  and an informational intake-per-kilo guide when a recent weight exists.

  Pure: takes the child, the days (oldest first, today last), `now`, and an
  optional recent weight. Feeds logged within `@episode_gap` of each other are
  treated as one feeding episode, so a topped-up bottle does not create a
  five-minute "interval".
  """

  alias Trygg.Families.Child
  alias Trygg.Reports.Day
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

    per_day = Enum.map(days, &day_row/1)
    feed_days = Enum.filter(per_day, &(&1.count > 0))
    last = List.last(feeds)

    by_period = %{
      day: interval_sample(intervals, :day, ready?),
      night: interval_sample(intervals, :night, ready?),
      overall: interval_sample(intervals, nil, ready?)
    }

    %{
      ready?: ready?,
      min_intervals: @min_intervals,
      per_day: per_day,
      count: Stats.sample(Enum.map(feed_days, & &1.count), feed_days != []),
      ml: Stats.sample(Enum.map(feed_days, & &1.ml), feed_days != []),
      intervals: by_period,
      last_feed_at: last && last.at,
      next_feed: next_feed(child, last, by_period, now),
      cluster: cluster(feeds, now),
      intake: intake(child, days, per_day, Keyword.get(opts, :weight))
    }
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

  defp day_row(%Day{} = day) do
    %{
      date: day.date,
      count: length(day.feeds),
      ml: day.feeds |> Enum.map(&ml/1) |> Enum.sum(),
      complete?: not day.now?
    }
  end

  defp ml(%{data: %{"amount_ml" => n}}) when is_number(n), do: n
  defp ml(_), do: 0

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

  defp intake(_child, _days, _per_day, nil), do: nil

  defp intake(%Child{} = child, days, per_day, %{grams: grams, date: %Date{} = weight_date})
       when is_number(grams) and grams > 0 do
    today =
      case List.last(days) do
        %Day{date: d} -> d
        _ -> Child.local_today(child)
      end

    age_days = Norms.age_days(child, today)
    guide = Norms.intake_ml_per_kg(age_days)
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

  defp intake(_child, _days, _per_day, _weight), do: nil
end
