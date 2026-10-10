defmodule Trygg.Reports.Day do
  @moduledoc """
  One local calendar day of a child's log, segmented into sleep/wake blocks,
  day vs night sleep, the overnight cluster (bedtime / morning wake), numbered
  naps and wake windows, plus feed and diaper markers.

  Pure: takes a child, a date, a list of entries, and `now`. Entries should
  cover a lookback of at least ~36 hours before midnight so last night's
  cluster can be reconstructed.
  """

  alias Trygg.Families.Child
  alias Trygg.Reports.FeedTiming

  # Night wakings shorter than this still count as the same overnight stretch.
  @max_cluster_gap_seconds 120 * 60
  # Pre-bed catnaps starting after `night_start - this` can join bedtime.
  @evening_lookback_seconds 3 * 3600
  # A feed logged inside an overnight sleep means the timer was left running
  # through a waking. Feeds this close to the sleep's start or end are the
  # bedtime / morning bottle logged a little early or late, not a waking.
  @feed_waking_margin_seconds 15 * 60
  # Feeds within this of each other inside one sleep are one waking (a top-up).
  @feed_waking_episode_seconds 30 * 60

  defstruct [
    :date,
    :bounds,
    :night_shading,
    :now?,
    :now_offset,
    :sleep_segments,
    :wake_segments,
    :feeds,
    :diapers,
    :breastfeeding_sessions,
    :breastfeeding_seconds,
    :day_sleep_seconds,
    :night_sleep_seconds,
    :total_sleep_seconds,
    :overnight_sleep_seconds,
    :bedtime,
    :morning_wake,
    :night_wakings,
    :naps,
    :wake_windows
  ]

  @doc "Builds a `%Day{}` for `date` from `entries` (any mix of types)."
  def build(%Child{} = child, %Date{} = date, entries, %DateTime{} = now)
      when is_list(entries) do
    now = DateTime.truncate(now, :second)
    {from, to} = Child.day_bounds(child, date)
    day_seconds = max(DateTime.diff(to, from, :second), 1)

    sleeps = Enum.filter(entries, &(&1.type == :sleep))

    feeds = moments(entries, :feeding)
    feed_seconds = FeedTiming.durations(feeds, moments(entries, :diaper))

    sleep_segments = clip_sleeps(sleeps, from, to, now)
    wake_segments = gaps(sleep_segments, from, to, now)

    {day_secs, night_secs} = split_day_night(child, date, sleep_segments)

    last_night = night_cluster(child, Date.add(date, -1), sleeps, {feeds, feed_seconds}, now)
    tonight = night_cluster(child, date, sleeps, {feeds, feed_seconds}, now)

    morning_wake = last_night && last_night.ended_at
    bedtime = tonight && tonight.started_at
    night_wakings = (tonight && tonight.wakings) || []

    naps = naps(sleeps, last_night, tonight, morning_wake, bedtime, from, to, now)
    wake_windows = wake_windows(naps, morning_wake, bedtime, now)

    %__MODULE__{
      date: date,
      bounds: {from, to},
      night_shading: night_shading(child, date, from, to),
      now?: within?(now, from, to),
      now_offset: if(within?(now, from, to), do: DateTime.diff(now, from, :second)),
      sleep_segments: annotate_offsets(sleep_segments, from, day_seconds),
      wake_segments: annotate_offsets(wake_segments, from, day_seconds),
      feeds: markers(entries, :feeding, from, to, day_seconds),
      diapers: markers(entries, :diaper, from, to, day_seconds),
      breastfeeding_sessions: count_started(entries, :breastfeeding, from, to),
      breastfeeding_seconds: timer_seconds(entries, :breastfeeding, from, to, now),
      day_sleep_seconds: day_secs,
      night_sleep_seconds: night_secs,
      total_sleep_seconds: day_secs + night_secs,
      overnight_sleep_seconds: overnight_seconds(child, date, sleeps, now),
      bedtime: bedtime,
      morning_wake: morning_wake,
      night_wakings: night_wakings,
      naps: naps,
      wake_windows: wake_windows
    }
  end

  defp count_started(entries, type, from, to) do
    Enum.count(entries, fn entry ->
      entry.type == type and DateTime.compare(entry.started_at, from) != :lt and
        DateTime.compare(entry.started_at, to) == :lt
    end)
  end

  defp timer_seconds(entries, type, from, to, now) do
    entries
    |> Enum.filter(fn entry ->
      entry.type == type and DateTime.compare(entry.started_at, to) == :lt and
        DateTime.compare(entry.ended_at || now, from) == :gt
    end)
    |> Enum.reduce(0, fn entry, total ->
      start = max_dt(entry.started_at, from)
      finish = min_dt(entry.ended_at || now, to)
      total + max(DateTime.diff(finish, start, :second), 0)
    end)
  end

  ## Sleep / wake on the calendar day -------------------------------------

  defp clip_sleeps(sleeps, from, to, now) do
    sleeps
    |> Enum.flat_map(fn e ->
      ended = e.ended_at || now

      if DateTime.compare(e.started_at, to) == :lt and DateTime.compare(ended, from) == :gt do
        start = max_dt(e.started_at, from)
        finish = min_dt(ended, to)
        seconds = max(DateTime.diff(finish, start, :second), 0)

        if seconds > 0 do
          running? = is_nil(e.ended_at) and DateTime.compare(finish, now) != :lt

          [
            %{
              id: e.id,
              entry: e,
              start: start,
              end: finish,
              running?: running?,
              location: e.data["location"],
              seconds: seconds
            }
          ]
        else
          []
        end
      else
        []
      end
    end)
    |> Enum.sort_by(& &1.start, DateTime)
  end

  defp gaps(sleeps, from, to, now) do
    horizon =
      cond do
        DateTime.compare(now, from) != :gt -> from
        DateTime.compare(now, to) == :lt -> now
        true -> to
      end

    if DateTime.compare(horizon, from) != :gt do
      []
    else
      {gaps, cursor, index} =
        Enum.reduce(sleeps, {[], from, 1}, fn seg, {acc, cursor, i} ->
          if DateTime.compare(seg.start, horizon) != :lt do
            {acc, cursor, i}
          else
            acc =
              if DateTime.compare(seg.start, cursor) == :gt do
                acc ++ [wake(i, cursor, min_dt(seg.start, horizon))]
              else
                acc
              end

            next_i = if DateTime.compare(seg.start, cursor) == :gt, do: i + 1, else: i
            {acc, max_dt(cursor, min_dt(seg.end, horizon)), next_i}
          end
        end)

      gaps =
        if DateTime.compare(horizon, cursor) == :gt do
          gaps ++ [wake(index, cursor, horizon)]
        else
          gaps
        end

      n = length(gaps)

      gaps
      |> Enum.with_index(1)
      |> Enum.map(fn {g, i} ->
        Map.merge(g, %{first?: i == 1, last?: i == n})
      end)
    end
  end

  defp wake(ordinal, start, finish) do
    seconds = max(DateTime.diff(finish, start, :second), 0)

    %{
      id: "wake-#{ordinal}",
      ordinal: ordinal,
      start: start,
      end: finish,
      running?: false,
      seconds: seconds
    }
  end

  defp moments(entries, type) do
    entries
    |> Enum.filter(&(&1.type == type))
    |> Enum.map(&%{id: &1.id, at: &1.started_at})
    |> Enum.sort_by(& &1.at, DateTime)
  end

  defp annotate_offsets(segments, from, day_seconds) do
    Enum.map(segments, fn s ->
      offset = DateTime.diff(s.start, from, :second)

      s
      |> Map.put(:offset, offset)
      |> Map.put(:ratio, offset / day_seconds)
      |> Map.put(:height_ratio, s.seconds / day_seconds)
    end)
  end

  defp markers(entries, type, from, to, day_seconds) do
    entries
    |> Enum.filter(&(&1.type == type))
    |> Enum.filter(fn e ->
      DateTime.compare(e.started_at, from) != :lt and DateTime.compare(e.started_at, to) == :lt
    end)
    |> Enum.sort_by(& &1.started_at, DateTime)
    |> Enum.map(fn e ->
      offset = DateTime.diff(e.started_at, from, :second)

      %{
        id: e.id,
        entry: e,
        at: e.started_at,
        offset: offset,
        ratio: offset / day_seconds,
        data: e.data || %{}
      }
    end)
  end

  defp split_day_night(child, date, segments) do
    day_from = Child.day_start_at(child, date)
    night_from = Child.night_start_at(child, date)

    Enum.reduce(segments, {0, 0}, fn seg, {day_acc, night_acc} ->
      day = overlap_seconds(seg.start, seg.end, day_from, night_from)
      {day_acc + day, night_acc + max(seg.seconds - day, 0)}
    end)
  end

  defp night_shading(child, date, from, to) do
    day_start = Child.day_start_at(child, date)
    night_start = Child.night_start_at(child, date)
    day_seconds = max(DateTime.diff(to, from, :second), 1)

    [{from, day_start}, {night_start, to}]
    |> Enum.filter(fn {a, b} -> DateTime.compare(a, b) == :lt end)
    |> Enum.map(fn {a, b} ->
      seconds = DateTime.diff(b, a, :second)
      offset = DateTime.diff(a, from, :second)

      %{
        start: a,
        end: b,
        offset: offset,
        seconds: seconds,
        ratio: offset / day_seconds,
        height_ratio: seconds / day_seconds
      }
    end)
  end

  defp overnight_seconds(child, date, sleeps, now) do
    {from, to} = Child.night_bounds(child, date)
    horizon = min_dt(now, to)

    sleeps
    |> Enum.map(fn e ->
      ended = e.ended_at || now
      start = max_dt(e.started_at, from)
      finish = min_dt(ended, horizon)
      max(DateTime.diff(finish, start, :second), 0)
    end)
    |> Enum.sum()
  end

  ## Overnight cluster ----------------------------------------------------

  defp night_cluster(child, night_date, sleeps, feeds, now) do
    {night_from, night_to} = Child.night_bounds(child, night_date)
    evening_from = DateTime.add(night_from, -@evening_lookback_seconds, :second)
    resolved = resolve_sleeps(sleeps, now)

    resolved
    |> Enum.filter(&overlaps_range?(&1, night_from, night_to))
    |> clusters()
    |> Enum.max_by(&overlap_with(&1, night_from, night_to), fn -> nil end)
    |> case do
      nil ->
        nil

      cluster ->
        cluster
        |> prepend_evening(resolved, evening_from)
        |> finalize_cluster(feeds)
    end
  end

  defp resolve_sleeps(sleeps, now) do
    sleeps
    |> Enum.map(fn e ->
      %{
        entry: e,
        start: e.started_at,
        end: e.ended_at || now,
        running?: is_nil(e.ended_at)
      }
    end)
    |> Enum.filter(fn s -> DateTime.compare(s.end, s.start) == :gt end)
    |> Enum.sort_by(& &1.start, DateTime)
  end

  defp prepend_evening(cluster, resolved, evening_from) do
    first = List.first(cluster)

    resolved
    |> Enum.filter(fn s ->
      DateTime.compare(s.start, evening_from) != :lt and
        DateTime.compare(s.start, first.start) == :lt
    end)
    |> Enum.sort_by(& &1.start, DateTime)
    |> Enum.reverse()
    |> Enum.reduce_while(cluster, fn s, acc ->
      head = List.first(acc)
      gap = DateTime.diff(head.start, s.end, :second)

      if gap >= 0 and gap <= @max_cluster_gap_seconds do
        {:cont, [s | acc]}
      else
        {:halt, acc}
      end
    end)
  end

  # Wakings are the gaps between the cluster's sleeps, plus any feed logged
  # while a sleep timer was left running.
  defp finalize_cluster(cluster, {feeds, feed_seconds}) do
    first = List.first(cluster)
    last = List.last(cluster)

    gap_wakings =
      cluster
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [a, b] ->
        gap = DateTime.diff(b.start, a.end, :second)

        if gap > 0 do
          [%{start: a.end, end: b.start, seconds: gap}]
        else
          []
        end
      end)

    feed_wakings =
      Enum.flat_map(cluster, fn s ->
        s
        |> feeds_during(feeds)
        |> feed_episodes()
        |> Enum.flat_map(&feed_waking(&1, s, feed_seconds))
      end)

    wakings = Enum.sort_by(gap_wakings ++ feed_wakings, & &1.start, DateTime)

    %{
      started_at: first.start,
      ended_at: if(last.running?, do: nil, else: last.end),
      running?: last.running?,
      sleeps: cluster,
      wakings: wakings
    }
  end

  defp feeds_during(sleep, feeds) do
    from = DateTime.add(sleep.start, @feed_waking_margin_seconds, :second)

    # A running timer has no morning bottle yet: a feed just logged is the
    # waking happening now.
    to =
      if sleep.running?,
        do: sleep.end,
        else: DateTime.add(sleep.end, -@feed_waking_margin_seconds, :second)

    Enum.filter(feeds, fn f ->
      DateTime.compare(f.at, from) != :lt and DateTime.compare(f.at, to) != :gt
    end)
  end

  # First feed of each top-up episode.
  defp feed_episodes(feeds) do
    feeds
    |> Enum.reduce([], fn
      f, [prev | _] = acc ->
        if DateTime.diff(f.at, prev.at, :second) < @feed_waking_episode_seconds,
          do: acc,
          else: [f | acc]

      f, [] ->
        [f]
    end)
    |> Enum.reverse()
  end

  # A feed timed from the diaper change before it runs from that change to the
  # feed. A change from before the sleep started means the feed was the
  # bedtime routine, not a waking. Untimed feeds have no known length.
  defp feed_waking(feed, sleep, feed_seconds) do
    case feed_seconds[feed.id] do
      nil ->
        [%{start: feed.at, end: feed.at, seconds: nil, feed?: true}]

      seconds ->
        start = DateTime.add(feed.at, -seconds, :second)

        if DateTime.compare(start, sleep.start) == :lt,
          do: [],
          else: [%{start: start, end: feed.at, seconds: seconds, feed?: true}]
    end
  end

  defp clusters(resolved) do
    Enum.reduce(resolved, [], fn s, acc ->
      case acc do
        [] ->
          [[s]]

        [current | rest] ->
          prev = List.last(current)
          gap = DateTime.diff(s.start, prev.end, :second)

          if gap <= @max_cluster_gap_seconds do
            [current ++ [s] | rest]
          else
            [[s] | acc]
          end
      end
    end)
    |> Enum.reverse()
  end

  defp overlaps_range?(s, from, to) do
    DateTime.compare(s.start, to) == :lt and DateTime.compare(s.end, from) == :gt
  end

  defp overlap_with(cluster, from, to) do
    Enum.reduce(cluster, 0, fn s, acc ->
      acc + overlap_seconds(s.start, s.end, from, to)
    end)
  end

  ## Naps & wake windows --------------------------------------------------

  defp naps(sleeps, last_night, tonight, morning_wake, bedtime, from, to, now) do
    night_ids =
      MapSet.new(
        ((last_night && last_night.sleeps) || []) ++ ((tonight && tonight.sleeps) || []),
        & &1.entry.id
      )

    sleeps
    |> Enum.reject(fn e -> MapSet.member?(night_ids, e.id) end)
    |> Enum.sort_by(& &1.started_at, DateTime)
    |> Enum.filter(fn e ->
      ended = e.ended_at || now

      in_day =
        DateTime.compare(e.started_at, from) != :lt and DateTime.compare(e.started_at, to) == :lt

      after_wake = is_nil(morning_wake) or DateTime.compare(e.started_at, morning_wake) != :lt
      before_bed = is_nil(bedtime) or DateTime.compare(ended, bedtime) != :gt
      in_day and after_wake and before_bed
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {e, i} ->
      ended = e.ended_at || now

      %{
        ordinal: i,
        id: e.id,
        entry: e,
        start: e.started_at,
        end: e.ended_at,
        running?: is_nil(e.ended_at),
        seconds: DateTime.diff(ended, e.started_at, :second)
      }
    end)
  end

  defp wake_windows(naps, morning_wake, bedtime, now) do
    if is_nil(morning_wake) do
      []
    else
      {windows, last_wake, ordinal} =
        Enum.reduce(naps, {[], morning_wake, 1}, fn nap, {acc, awake_from, i} ->
          if is_nil(awake_from) do
            {acc, nil, i}
          else
            seconds = max(DateTime.diff(nap.start, awake_from, :second), 0)
            acc = append_window(acc, i, awake_from, nap.start, seconds, false)
            next_i = if seconds > 0, do: i + 1, else: i

            if nap.running? do
              {acc, nil, next_i}
            else
              {acc, nap.end, next_i}
            end
          end
        end)

      cond do
        is_nil(last_wake) ->
          windows

        bedtime ->
          seconds = max(DateTime.diff(bedtime, last_wake, :second), 0)
          append_window(windows, ordinal, last_wake, bedtime, seconds, false)

        true ->
          seconds = max(DateTime.diff(now, last_wake, :second), 0)
          append_window(windows, ordinal, last_wake, now, seconds, true)
      end
    end
  end

  defp append_window(windows, _ordinal, _start, _finish, seconds, _open?) when seconds <= 0,
    do: windows

  defp append_window(windows, ordinal, start, finish, seconds, open?) do
    windows ++
      [
        %{
          ordinal: ordinal,
          start: start,
          end: finish,
          seconds: seconds,
          open?: open?
        }
      ]
  end

  ## Time helpers ---------------------------------------------------------

  defp within?(dt, from, to),
    do: DateTime.compare(dt, from) != :lt and DateTime.compare(dt, to) == :lt

  defp overlap_seconds(a0, a1, b0, b1) do
    start = max_dt(a0, b0)
    finish = min_dt(a1, b1)
    max(DateTime.diff(finish, start, :second), 0)
  end

  defp max_dt(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
  defp min_dt(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)
end
