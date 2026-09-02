defmodule Trygg.Reports.Insights do
  @moduledoc """
  Sleep statistics and predictions over a window of `%Trygg.Reports.Day{}`.

  Uses median + IQR (robust to outliers) with mean as a secondary number.
  Returns `nil` for a statistic when the sample is smaller than `@min_sample`.

  Predictions (next nap, bedtime, wake pressure) are always built from the
  most recent `@prediction_days` days so they follow the current schedule even
  when the caller is looking at a 90-day trend. When the child's own history is
  too thin for an ordinal, the prediction falls back to an age-band prior from
  `Trygg.Reports.Norms` and says so via `source: :age_prior`.
  """

  alias Trygg.Families.Child
  alias Trygg.Reports.Day
  alias Trygg.Reports.Norms
  alias Trygg.Reports.Stats

  @min_sample 3
  @heatmap_bins 48
  @rolling 7
  @prediction_days 14
  # Wake pressure switches from :fresh to :approaching this long before the
  # typical window ends.
  @approach_seconds 15 * 60

  @doc """
  Summarizes `days` (oldest first) and builds a prediction for `today`.

  `today` should be the `%Day{}` for the child's current local date; it may
  also be the last element of `days`.
  """
  def summarize(%Child{} = child, days, %Day{} = today, %DateTime{} = now)
      when is_list(days) do
    now = DateTime.truncate(now, :second)
    sleep_days = Enum.count(days, &(&1.total_sleep_seconds > 0))
    ready? = sleep_days >= @min_sample

    totals = totals(child, days, ready?)
    nap_stats = nap_stats(days, ready?)
    wake_stats = wake_stats(days, ready?)
    morning = clock_stat(child, Enum.map(days, & &1.morning_wake), ready?, false)
    bedtime = clock_stat(child, Enum.map(days, & &1.bedtime), ready?, true)

    recent = Enum.take(days, -@prediction_days)
    recent_ready? = Enum.count(recent, &(&1.total_sleep_seconds > 0)) >= @min_sample

    recent_stats = %{
      naps: nap_stats(recent, recent_ready?),
      wake_windows: wake_stats(recent, recent_ready?),
      morning_wake: clock_stat(child, Enum.map(recent, & &1.morning_wake), recent_ready?, false),
      bedtime: clock_stat(child, Enum.map(recent, & &1.bedtime), recent_ready?, true),
      age_days: Norms.age_days(child, today.date)
    }

    %{
      sample_days: length(days),
      ready?: ready?,
      min_sample: @min_sample,
      totals: totals,
      naps: nap_stats,
      wake_windows: wake_stats,
      morning_wake: morning,
      bedtime: bedtime,
      night_wakings: night_waking_stats(days, ready?),
      heatmap: heatmap(days, ready?),
      longest_night: longest_night(days),
      prediction: predict(child, today, recent_stats, now)
    }
  end

  @doc "How many days a prediction is based on."
  def prediction_days, do: @prediction_days

  ## Totals / trends ------------------------------------------------------

  defp totals(child, days, ready?) do
    series =
      days
      |> Enum.with_index()
      |> Enum.map(fn {d, i} ->
        window = days |> Enum.take(i + 1) |> Enum.take(-@rolling)
        rolling = Stats.mean(Enum.map(window, & &1.total_sleep_seconds))

        span = day_span(d)

        %{
          date: d.date,
          total: d.total_sleep_seconds,
          day: d.day_sleep_seconds,
          night: d.night_sleep_seconds,
          overnight: d.overnight_sleep_seconds,
          awake: max(span - d.total_sleep_seconds, 0),
          rolling: rolling,
          wake_minutes: d.morning_wake && minutes_from_midnight(child, d.morning_wake, false),
          bed_minutes: d.bedtime && minutes_from_midnight(child, d.bedtime, true)
        }
      end)

    totals = Enum.map(days, & &1.total_sleep_seconds)
    daysleep = Enum.map(days, & &1.day_sleep_seconds)
    nightsleep = Enum.map(days, & &1.night_sleep_seconds)
    overnight = Enum.map(days, & &1.overnight_sleep_seconds)

    %{
      per_day: series,
      total: Stats.sample(totals, ready?),
      day: Stats.sample(daysleep, ready?),
      night: Stats.sample(nightsleep, ready?),
      overnight: Stats.sample(overnight, ready?),
      slope: if(ready?, do: slope_minutes_per_day(totals))
    }
  end

  defp day_span(%Day{now?: true, now_offset: offset}) when is_integer(offset), do: max(offset, 0)

  defp day_span(%Day{bounds: {from, to}}), do: max(DateTime.diff(to, from, :second), 0)

  defp longest_night(days) do
    case Enum.max_by(days, & &1.overnight_sleep_seconds, fn -> nil end) do
      nil -> nil
      %Day{overnight_sleep_seconds: 0} -> nil
      %Day{} = d -> %{date: d.date, seconds: d.overnight_sleep_seconds}
    end
  end

  defp slope_minutes_per_day(ys) do
    case Stats.slope(ys) do
      nil ->
        nil

      seconds ->
        minutes = seconds / 60.0
        %{seconds_per_day: seconds, minutes_per_day: minutes, label: slope_label(minutes)}
    end
  end

  defp slope_label(minutes) when abs(minutes) < 1.0, do: "steady"

  defp slope_label(minutes) do
    rounded = round(minutes)
    sign = if rounded > 0, do: "+", else: ""
    "#{sign}#{rounded} min/day"
  end

  ## Naps / wake windows --------------------------------------------------

  defp nap_stats(days, ready?) do
    counts = Enum.map(days, &length(&1.naps))
    closed = days |> Enum.flat_map(& &1.naps) |> Enum.reject(& &1.running?)
    by_ordinal = duration_by_ordinal(closed, ready?)

    %{
      count: Stats.sample(counts, ready?),
      by_ordinal: by_ordinal
    }
  end

  defp wake_stats(days, ready?) do
    closed =
      days
      |> Enum.flat_map(& &1.wake_windows)
      |> Enum.reject(& &1.open?)

    seconds = Enum.map(closed, & &1.seconds)
    overall = closed |> Enum.map(& &1.seconds) |> Stats.sample(ready?)

    %{
      overall: Map.put(overall, :quartiles, if(ready?, do: Stats.quartiles(seconds))),
      by_ordinal: duration_by_ordinal(closed, ready?)
    }
  end

  defp duration_by_ordinal(_items, false), do: []

  defp duration_by_ordinal(items, true) do
    items
    |> Enum.group_by(& &1.ordinal)
    |> Enum.sort_by(fn {ord, _} -> ord end)
    |> Enum.map(fn {ord, group} ->
      seconds = Enum.map(group, & &1.seconds)

      %{ordinal: ord}
      |> Map.merge(Stats.sample(seconds, true))
      |> Map.put(:quartiles, Stats.quartiles(seconds))
    end)
  end

  defp night_waking_stats(days, ready?) do
    counts = Enum.map(days, &length(&1.night_wakings))
    durations = days |> Enum.flat_map(& &1.night_wakings) |> Enum.map(& &1.seconds)
    %{count: Stats.sample(counts, ready?), duration: Stats.sample(durations, ready?)}
  end

  ## Clock stats ----------------------------------------------------------

  defp clock_stat(_child, _values, false, _bedtime?), do: nil_sample_clock()

  defp clock_stat(child, values, true, bedtime?) do
    minutes =
      values
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&minutes_from_midnight(child, &1, bedtime?))

    n = length(minutes)

    if n < @min_sample do
      nil_sample_clock()
    else
      med = Stats.median(minutes)
      mn = Stats.mean(minutes)
      iqr = Stats.iqr(minutes)

      %{
        n: n,
        median_minutes: med,
        mean_minutes: mn,
        iqr_minutes: iqr,
        median_label: format_hhmm(med),
        mean_label: format_hhmm(mn),
        consistency_label: consistency_label(iqr)
      }
    end
  end

  defp nil_sample_clock do
    %{
      n: 0,
      median_minutes: nil,
      mean_minutes: nil,
      iqr_minutes: nil,
      median_label: nil,
      mean_label: nil,
      consistency_label: nil
    }
  end

  defp minutes_from_midnight(%Child{timezone: tz}, %DateTime{} = dt, bedtime?) do
    local = DateTime.shift_zone!(dt, tz)
    mins = local.hour * 60 + local.minute
    if bedtime? and mins < 12 * 60, do: mins + 24 * 60, else: mins
  end

  defp consistency_label(nil), do: nil
  defp consistency_label(iqr) when iqr < 15, do: "very consistent"
  defp consistency_label(iqr) when iqr < 30, do: "fairly consistent"
  defp consistency_label(iqr) when iqr < 60, do: "varies by ~#{round(iqr)} min"
  defp consistency_label(iqr), do: "varies by ~#{round(iqr / 60)}h"

  defp format_hhmm(nil), do: nil

  defp format_hhmm(minutes) when is_number(minutes) do
    minutes = minutes |> round() |> rem(24 * 60)
    minutes = if minutes < 0, do: minutes + 24 * 60, else: minutes
    hour = div(minutes, 60)
    min = rem(minutes, 60)
    :io_lib.format("~2..0B:~2..0B", [hour, min]) |> IO.iodata_to_binary()
  end

  ## Heatmap --------------------------------------------------------------

  defp heatmap(_days, false), do: nil

  defp heatmap(days, true) do
    n = length(days)
    bin_seconds = div(24 * 3600, @heatmap_bins)

    bins =
      for i <- 0..(@heatmap_bins - 1) do
        asleep =
          Enum.count(days, fn day ->
            {from, _to} = day.bounds
            bin_start = DateTime.add(from, i * bin_seconds, :second)
            bin_end = DateTime.add(from, (i + 1) * bin_seconds, :second)

            Enum.any?(day.sleep_segments, fn s ->
              DateTime.compare(s.start, bin_end) == :lt and
                DateTime.compare(s.end, bin_start) == :gt
            end)
          end)

        share = asleep / n
        hour = i * 24 / @heatmap_bins

        %{index: i, share: share, hour: hour}
      end

    %{bins: bins, bin_count: @heatmap_bins}
  end

  ## Predictions ----------------------------------------------------------

  defp predict(child, today, stats, now) do
    morning = morning_prediction(child, today, stats)
    asleep? = Enum.any?(today.sleep_segments, & &1.running?)
    completed = Enum.reject(today.naps, & &1.running?)
    n_done = length(completed)
    typical = typical_nap_count(stats)

    last_wake =
      cond do
        n_done > 0 -> List.last(completed).end
        today.morning_wake -> today.morning_wake
        true -> nil
      end

    bedtime = bedtime_prediction(child, today, stats, last_wake, n_done, typical)

    if asleep? do
      %{
        state: :asleep,
        morning_wake: morning,
        next_nap: nil,
        wake_pressure: nil,
        bedtime: bedtime,
        schedule: []
      }
    else
      next_nap = next_nap_prediction(child, last_wake, n_done, typical, stats, now)
      schedule = rest_schedule(child, last_wake, n_done, typical, stats, bedtime)

      %{
        state: :awake,
        morning_wake: morning,
        next_nap: next_nap,
        wake_pressure: wake_pressure(last_wake, n_done, stats, now),
        bedtime: bedtime,
        schedule: schedule
      }
    end
  end

  defp morning_prediction(child, today, stats) do
    cond do
      today.morning_wake ->
        %{
          actual?: true,
          at: today.morning_wake,
          label: Child.local_clock(child, today.morning_wake)
        }

      stats.morning_wake.median_minutes ->
        at = minutes_to_dt(child, today.date, stats.morning_wake.median_minutes)

        %{
          actual?: false,
          at: at,
          label: stats.morning_wake.median_label
        }

      true ->
        nil
    end
  end

  defp next_nap_prediction(_child, nil, _n_done, _typical, _stats, _now), do: nil

  defp next_nap_prediction(_child, _last_wake, n_done, typical, _stats, _now)
       when is_integer(typical) and n_done >= typical and typical > 0,
       do: nil

  defp next_nap_prediction(child, last_wake, n_done, _typical, stats, now) do
    ordinal = n_done + 1

    case wake_estimate(stats, ordinal) do
      nil ->
        nil

      %{typical: ww, range: range, source: source} ->
        at = DateTime.add(last_wake, round(ww), :second)

        %{
          ordinal: ordinal,
          at: at,
          label: Child.local_clock(child, at),
          in_seconds: DateTime.diff(at, now, :second),
          range: range && range_labels(child, last_wake, range),
          source: source
        }
    end
  end

  defp range_labels(child, last_wake, {lo, hi}) do
    from = DateTime.add(last_wake, round(lo), :second)
    to = DateTime.add(last_wake, round(hi), :second)

    %{
      from: from,
      to: to,
      label: "#{Child.local_clock(child, from)}–#{Child.local_clock(child, to)}"
    }
  end

  # How long they've been up versus how long they usually last before this
  # nap. `:past` means they are beyond their usual upper quartile (or the age
  # prior's upper bound) — overtiredness territory.
  defp wake_pressure(nil, _n_done, _stats, _now), do: nil

  defp wake_pressure(last_wake, n_done, stats, now) do
    awake = max(DateTime.diff(now, last_wake, :second), 0)

    case wake_estimate(stats, n_done + 1) do
      nil ->
        %{awake_seconds: awake, typical_seconds: nil, upper_seconds: nil, state: nil, source: nil}

      %{typical: typical, range: range, source: source} ->
        upper =
          case range do
            {_lo, hi} -> max(hi, typical)
            nil -> typical + @approach_seconds
          end

        state =
          cond do
            awake < typical - @approach_seconds -> :fresh
            awake <= upper -> :approaching
            true -> :past
          end

        %{
          awake_seconds: awake,
          typical_seconds: typical,
          upper_seconds: upper,
          state: state,
          source: source
        }
    end
  end

  defp bedtime_prediction(child, today, stats, last_wake, n_done, typical) do
    median_mins = stats.bedtime.median_minutes
    median_dt = median_mins && minutes_to_dt(child, today.date, median_mins)
    last_ww = wake_median(stats, :last)

    from_wake =
      if last_wake && last_ww && typical > 0 && n_done >= typical do
        DateTime.add(last_wake, round(last_ww), :second)
      end

    cond do
      median_dt && from_wake ->
        unix = div(DateTime.to_unix(median_dt) + DateTime.to_unix(from_wake), 2)
        at = DateTime.from_unix!(unix) |> DateTime.truncate(:second)

        %{at: at, label: Child.local_clock(child, at), estimate?: true}

      median_dt ->
        %{at: median_dt, label: Child.local_clock(child, median_dt), estimate?: true}

      from_wake ->
        %{at: from_wake, label: Child.local_clock(child, from_wake), estimate?: true}

      true ->
        nil
    end
  end

  defp rest_schedule(_child, nil, _n_done, _typical, _stats, _bedtime), do: []
  defp rest_schedule(_child, _last, _n_done, 0, _stats, bedtime), do: wrap_bed(bedtime)

  defp rest_schedule(child, last_wake, n_done, typical, stats, bedtime) do
    nap_ords =
      if is_integer(typical) and n_done < typical do
        Enum.to_list((n_done + 1)..typical)
      else
        []
      end

    {items, _cursor} =
      Enum.reduce(nap_ords, {[], last_wake}, fn ord, {acc, t} ->
        ww = round(wake_median(stats, ord) || 0)
        nap_len = round(nap_median(stats, ord) || 0)
        start = add_seconds(t, ww)
        finish = add_seconds(start, nap_len)

        item = %{
          kind: :nap,
          ordinal: ord,
          start: start,
          end: finish,
          label: "Nap #{ord} · #{Child.local_clock(child, start)}"
        }

        {acc ++ [item], finish}
      end)

    items ++ wrap_bed(bedtime)
  end

  defp add_seconds(dt, seconds), do: DateTime.add(dt, round(seconds), :second)

  defp wrap_bed(nil), do: []

  defp wrap_bed(%{at: at, label: label}) do
    [%{kind: :bed, ordinal: nil, start: at, end: at, label: "Bedtime · #{label}"}]
  end

  defp typical_nap_count(%{naps: %{count: %{median: med}}}) when is_number(med) do
    round(med)
  end

  defp typical_nap_count(_), do: 0

  # The child's own median wake window for this ordinal when there is one,
  # otherwise the age-band prior (midpoint, with the band as the range).
  defp wake_estimate(stats, ordinal) do
    case wake_row(stats, ordinal) do
      %{median: med, quartiles: q} when is_number(med) ->
        %{typical: med, range: q, source: :history}

      _ ->
        case Norms.wake_window_range(stats[:age_days]) do
          {lo, hi} -> %{typical: (lo + hi) / 2, range: {lo, hi}, source: :age_prior}
          nil -> nil
        end
    end
  end

  defp wake_row(stats, ordinal) when is_integer(ordinal) do
    case Enum.find(stats.wake_windows.by_ordinal, &(&1.ordinal == ordinal)) do
      %{median: med} = row when is_number(med) -> row
      _ -> stats.wake_windows.overall
    end
  end

  defp wake_median(stats, :last) do
    case List.last(stats.wake_windows.by_ordinal) do
      %{median: med} when is_number(med) -> med
      _ -> stats.wake_windows.overall.median
    end
  end

  defp wake_median(stats, ordinal) when is_integer(ordinal) do
    case wake_estimate(stats, ordinal) do
      %{typical: t} -> t
      nil -> nil
    end
  end

  defp nap_median(stats, ordinal) do
    case Enum.find(stats.naps.by_ordinal, &(&1.ordinal == ordinal)) do
      %{median: med} -> med
      _ -> nil
    end
  end

  defp minutes_to_dt(%Child{} = child, %Date{} = date, minutes) when is_number(minutes) do
    total = round(minutes)
    extra_days = div(total, 24 * 60)
    mins = rem(total, 24 * 60)
    time = Time.new!(div(mins, 60), rem(mins, 60), 0)
    Child.at_local(child, Date.add(date, extra_days), time)
  end
end
