defmodule Trygg.Reports.Insights do
  @moduledoc """
  Sleep statistics and predictions over a window of `%Trygg.Reports.Day{}`.

  Uses median + IQR (robust to outliers) with mean as a secondary number.
  Returns `nil` for a statistic when the sample is smaller than `@min_sample`.

  Predictions (next nap, bedtime, wake pressure) are built from the most recent
  `@recency_window_days` days, each day exponentially down-weighted by age
  (`@recency_half_life_days` half-life), so they track the current schedule
  even when the caller is looking at a 90-day trend. Each per-ordinal estimate
  is a shrinkage blend of the child's own (recency-weighted) history and the
  age prior from `Trygg.Reports.Norms`: `w = eff_n / (eff_n + @blend_k)`.
  `source` reports which side dominates — `:history`, `:blended`, or
  `:age_prior` — so a brand-new child still gets a prediction (`:age_prior`)
  and it slides toward `:history` as real days accumulate.
  """

  alias Trygg.Families.Child
  alias Trygg.Reports.Day
  alias Trygg.Reports.Norms
  alias Trygg.Reports.Stats

  @min_sample 3
  @heatmap_bins 48
  @rolling 7
  # Recent history the prediction is weighted over (a cheap pre-filter — the
  # half-life does the real work).
  @recency_window_days 21
  @recency_half_life_days 6
  # Shrinkage constant: how many effective days of history it takes to pull the
  # estimate halfway from the age prior to the child's own pattern.
  @blend_k 3.0
  # At or above this many effective days for an ordinal, `source` is `:history`;
  # below ~1, `:age_prior`; in between, `:blended`.
  @history_source_eff_n 5.0
  # A per-ordinal nap-start clock is only used as an anchor when it is this
  # stable (weighted IQR, minutes) and rests on at least this many effective
  # days.
  @stable_clock_iqr_minutes 45
  @min_clock_eff_n 2.0
  # Wake pressure switches from :fresh to :approaching this long before the
  # typical window ends.
  @approach_seconds 15 * 60
  # Nap-debt bedtime shift: only when the day is trailing typical daytime sleep
  # by more than this, capped at this much earlier, never before 18:00 local.
  @nap_debt_threshold 30 * 60
  @max_bedtime_shift 45 * 60
  @earliest_bedtime_minutes 18 * 60
  # In a suspected nap transition, predicted ranges are widened by this factor
  # (on the half-width) to stop the model chasing a shifting schedule.
  @transition_range_factor 1.5
  # A per-kind ledger bias is applied at half strength, capped here.
  @bias_damp 0.5
  @max_bias_seconds 20 * 60

  @doc """
  Summarizes `days` (oldest first) and builds a prediction for `today`.

  `today` should be the `%Day{}` for the child's current local date; it may
  also be the last element of `days`.

  `opts` (all optional):

    * `:recent_days` — a longer `%Day{}` list (oldest first) to build the
      *prediction* from when the descriptive `days` is a short viewed window;
      the nap-transition signal needs ~2 weeks of history regardless of what
      the caller is looking at. Defaults to `days`.
    * `:half_life_days` — override the recency half-life (a regime shift halves
      it so the model re-locks faster on the new pattern).
    * `:bias` — `%{next_nap: seconds, bedtime: seconds}` signed mean error to
      correct out, applied at half strength and capped.
  """
  def summarize(%Child{} = child, days, %Day{} = today, %DateTime{} = now, opts \\ [])
      when is_list(days) do
    now = DateTime.truncate(now, :second)
    sleep_days = Enum.count(days, &(&1.total_sleep_seconds > 0))
    ready? = sleep_days >= @min_sample

    totals = totals(child, days, ready?)
    nap_stats = nap_stats(days, ready?)
    wake_stats = wake_stats(days, ready?)
    morning = clock_stat(child, Enum.map(days, & &1.morning_wake), ready?, false)
    bedtime = clock_stat(child, Enum.map(days, & &1.bedtime), ready?, true)

    half_life = opts[:half_life_days] || @recency_half_life_days
    recent = Enum.take(opts[:recent_days] || days, -@recency_window_days)
    recent_ready? = Enum.count(recent, &(&1.total_sleep_seconds > 0)) >= @min_sample
    weighted = recency_weights(recent, today.date, half_life)

    recent_stats = %{
      naps: weighted_nap_stats(child, weighted, today.date),
      wake_windows: weighted_wake_stats(weighted),
      morning_wake: clock_stat(child, Enum.map(recent, & &1.morning_wake), recent_ready?, false),
      bedtime: clock_stat(child, Enum.map(recent, & &1.bedtime), recent_ready?, true),
      age_days: Norms.age_days(child, today.date)
    }

    recent_stats = Map.put(recent_stats, :transition?, transition?(weighted, today.date))

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
      prediction: predict(child, today, recent_stats, now, bias_map(opts[:bias]))
    }
  end

  @doc "How many days of recent history a prediction is weighted over."
  def prediction_days, do: @recency_window_days

  @doc "The default recency half-life, in days (a regime shift halves this)."
  def recency_half_life_days, do: @recency_half_life_days

  defp bias_map(nil), do: %{next_nap: 0, bedtime: 0}

  defp bias_map(%{} = bias) do
    %{
      next_nap: capped_bias(bias[:next_nap]),
      bedtime: capped_bias(bias[:bedtime])
    }
  end

  defp capped_bias(nil), do: 0

  defp capped_bias(seconds) when is_number(seconds) do
    (seconds * @bias_damp) |> round() |> max(-@max_bias_seconds) |> min(@max_bias_seconds)
  end

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

  ## Recency-weighted stats (prediction path only) -----------------------

  # `[{day, weight}]`, weight = 0.5 ^ (days_before_today / half_life); today
  # itself weighs 1.0.
  defp recency_weights(days, today_date, half_life) do
    Enum.map(days, fn day ->
      days_ago = max(Date.diff(today_date, day.date), 0)
      {day, :math.pow(0.5, days_ago / half_life)}
    end)
  end

  defp weighted_wake_stats(weighted_days) do
    closed =
      for {day, w} <- weighted_days,
          window <- day.wake_windows,
          not window.open? do
        {window.seconds, window.ordinal, w}
      end

    %{
      overall: weighted_summary(for {s, _o, w} <- closed, do: {s, w}),
      by_ordinal:
        closed
        |> Enum.group_by(&elem(&1, 1))
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {ordinal, group} ->
          group
          |> Enum.map(fn {s, _o, w} -> {s, w} end)
          |> weighted_summary()
          |> Map.put(:ordinal, ordinal)
        end)
    }
  end

  # Nap *count* is taken from complete prior days only (today's partial count
  # would otherwise drag the median down, and today carries the most weight).
  # Per-ordinal nap *durations* and *start clocks* use every day, today
  # included.
  defp weighted_nap_stats(child, weighted_days, today_date) do
    complete = for {day, w} <- weighted_days, day.date != today_date, do: {day, w}
    count_pairs = for {day, w} <- complete, do: {length(day.naps), w}
    day_total_pairs = for {day, w} <- complete, do: {closed_nap_seconds(day), w}

    closed =
      for {day, w} <- weighted_days,
          nap <- day.naps,
          not nap.running? do
        {nap, w}
      end

    %{
      count: %{
        median: Stats.weighted_median(pairs_values(count_pairs), pairs_weights(count_pairs)),
        eff_n: Stats.effective_n(pairs_weights(count_pairs))
      },
      day_total_median:
        Stats.weighted_median(pairs_values(day_total_pairs), pairs_weights(day_total_pairs)),
      by_ordinal:
        closed
        |> Enum.group_by(fn {nap, _w} -> nap.ordinal end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {ordinal, group} ->
          durations = Enum.map(group, fn {nap, w} -> {nap.seconds, w} end)

          starts =
            Enum.map(group, fn {nap, w} -> {minutes_from_midnight(child, nap.start, false), w} end)

          %{
            ordinal: ordinal,
            median: Stats.weighted_median(pairs_values(durations), pairs_weights(durations)),
            eff_n: Stats.effective_n(pairs_weights(durations)),
            start_clock: Stats.weighted_median(pairs_values(starts), pairs_weights(starts)),
            start_clock_iqr: weighted_iqr(starts)
          }
        end)
    }
  end

  defp weighted_iqr(pairs) when length(pairs) < 4, do: nil

  defp weighted_iqr(pairs) do
    values = pairs_values(pairs)
    weights = pairs_weights(pairs)

    Stats.weighted_quantile(values, weights, 0.75) -
      Stats.weighted_quantile(values, weights, 0.25)
  end

  defp weighted_summary([]), do: %{median: nil, n: 0, eff_n: 0.0, quartiles: nil}

  defp weighted_summary(pairs) do
    values = pairs_values(pairs)
    weights = pairs_weights(pairs)

    %{
      median: Stats.weighted_median(values, weights),
      n: length(pairs),
      eff_n: Stats.effective_n(weights),
      quartiles: weighted_quartiles(values, weights)
    }
  end

  defp weighted_quartiles(values, _weights) when length(values) < 4, do: nil

  defp weighted_quartiles(values, weights) do
    {Stats.weighted_quantile(values, weights, 0.25),
     Stats.weighted_quantile(values, weights, 0.75)}
  end

  defp pairs_values(pairs), do: Enum.map(pairs, &elem(&1, 0))
  defp pairs_weights(pairs), do: Enum.map(pairs, &elem(&1, 1))

  defp closed_nap_seconds(day) do
    day.naps |> Enum.reject(& &1.running?) |> Enum.map(& &1.seconds) |> Enum.sum()
  end

  ## Nap-transition signal ----------------------------------------------

  # True when the child looks mid-transition: their own nap count has dropped
  # versus a couple of weeks ago, or the last wake window of the day has crept
  # up sharply. Read from the child's own log — an age prior alone doesn't
  # decide it, since these transitions are readiness-driven.
  defp transition?(weighted_days, today_date) do
    nap_count_dropping?(weighted_days, today_date) or
      last_window_trend(weighted_days, today_date) == :rising
  end

  defp nap_count_dropping?(weighted_days, today_date) do
    per_day =
      for {day, w} <- weighted_days, day.date != today_date do
        {length(day.naps), w, Date.diff(today_date, day.date)}
      end

    recent = for {n, w, ago} <- per_day, ago <= 7, do: {n, w}
    older = for {n, w, ago} <- per_day, ago >= 8 and ago <= 18, do: {n, w}

    if length(recent) >= 3 and length(older) >= 3 do
      r = Stats.weighted_median(pairs_values(recent), pairs_weights(recent))
      o = Stats.weighted_median(pairs_values(older), pairs_weights(older))
      is_number(r) and is_number(o) and o - r >= 0.5
    else
      false
    end
  end

  defp last_window_trend(weighted_days, today_date) do
    per_day =
      for {day, w} <- weighted_days,
          last =
            day.wake_windows
            |> Enum.reject(& &1.open?)
            |> Enum.max_by(& &1.ordinal, fn -> nil end),
          not is_nil(last) do
        {last.seconds, w, Date.diff(today_date, day.date)}
      end

    recent = for {s, w, ago} <- per_day, ago <= 7, do: {s, w}
    older = for {s, w, ago} <- per_day, ago >= 8 and ago <= 14, do: {s, w}

    if length(recent) >= 3 and length(older) >= 3 do
      rm = Stats.weighted_median(pairs_values(recent), pairs_weights(recent))
      om = Stats.weighted_median(pairs_values(older), pairs_weights(older))

      if is_number(rm) and is_number(om) and om > 0 and rm > om * 1.2, do: :rising, else: :steady
    end
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

  defp predict(child, today, stats, now, bias) do
    morning = morning_prediction(child, today, stats)
    asleep? = Enum.any?(today.sleep_segments, & &1.running?)
    completed = Enum.reject(today.naps, & &1.running?)
    n_done = length(completed)
    typical = typical_nap_count(stats)
    transition? = stats[:transition?] == true

    last_nap = if n_done > 0, do: List.last(completed)

    last_wake =
      cond do
        last_nap -> last_nap.end
        today.morning_wake -> today.morning_wake
        true -> nil
      end

    bedtime =
      bedtime_prediction(child, today, stats, last_wake, n_done, typical, bias[:bedtime])

    base =
      if asleep? do
        %{
          state: :asleep,
          next_nap: nil,
          wake_pressure: nil,
          schedule: []
        }
      else
        %{
          state: :awake,
          next_nap:
            next_nap_prediction(
              child,
              today,
              last_wake,
              n_done,
              typical,
              last_nap,
              stats,
              now,
              transition?,
              bias[:next_nap]
            ),
          wake_pressure:
            wake_pressure(last_wake, n_done, typical, last_nap, stats, now, transition?),
          schedule: rest_schedule(child, today, last_wake, n_done, typical, stats, bedtime, now)
        }
      end

    Map.merge(base, %{
      anchor_ts: last_wake,
      morning_wake: morning,
      bedtime: bedtime,
      transition?: transition?
    })
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

  defp next_nap_prediction(_c, _t, nil, _n, _typ, _ln, _s, _now, _tr, _bias), do: nil

  defp next_nap_prediction(_c, _t, _lw, n_done, typical, _ln, _s, _now, _tr, _bias)
       when is_integer(typical) and n_done >= typical and typical > 0,
       do: nil

  defp next_nap_prediction(
         child,
         today,
         last_wake,
         n_done,
         typical,
         last_nap,
         stats,
         now,
         transition?,
         bias
       ) do
    ordinal = n_done + 1

    case wake_estimate(stats, ordinal, typical) do
      nil ->
        nil

      est ->
        %{typical: ww, range: range, source: source} =
          adjust_for_last_nap(est, last_nap, n_done, stats)

        cumulative = DateTime.add(last_wake, round(ww), :second)

        at =
          child
          |> anchor_to_clock(cumulative, today, stats, ordinal, typical, last_wake)
          |> DateTime.add(bias, :second)

        shift = DateTime.diff(at, cumulative, :second)
        range = range && widen_if(range, transition?)

        %{
          ordinal: ordinal,
          at: at,
          label: Child.local_clock(child, at),
          in_seconds: DateTime.diff(at, now, :second),
          range: range && range_labels(child, last_wake, range, shift),
          source: source
        }
    end
  end

  defp range_labels(child, last_wake, {lo, hi}, shift) do
    from = DateTime.add(last_wake, round(lo) + shift, :second)
    to = DateTime.add(last_wake, round(hi) + shift, :second)

    %{
      from: from,
      to: to,
      label: "#{Child.local_clock(child, from)}–#{Child.local_clock(child, to)}"
    }
  end

  # In a suspected nap transition, stretch a range about its centre so the shown
  # window is honestly wider while the schedule is unsettled.
  defp widen_if(range, false), do: range

  defp widen_if({lo, hi}, true) do
    c = (lo + hi) / 2
    half = (hi - lo) / 2 * @transition_range_factor
    {c - half, c + half}
  end

  # Pull a purely cumulative-from-wake target toward the child's historical
  # start-clock for this nap ordinal, when that clock is stable. `beta` rises
  # through the day so a single early/late nap doesn't drag every later one.
  # Never returns a time before the morning wake.
  defp anchor_to_clock(child, cumulative, today, stats, ordinal, expected, last_wake) do
    row = nap_row(stats, ordinal)

    anchored =
      if stable_clock?(row) do
        clock_dt = minutes_to_dt(child, today.date, row.start_clock)

        if DateTime.compare(clock_dt, last_wake) == :gt do
          blend_datetimes(cumulative, clock_dt, clock_beta(ordinal, expected))
        else
          cumulative
        end
      else
        cumulative
      end

    clamp_after(anchored, today.morning_wake)
  end

  defp nap_row(stats, ordinal), do: Enum.find(stats.naps.by_ordinal, &(&1.ordinal == ordinal))

  defp stable_clock?(%{start_clock: c, start_clock_iqr: iqr, eff_n: eff})
       when is_number(c) and is_number(iqr) do
    iqr <= @stable_clock_iqr_minutes and eff >= @min_clock_eff_n
  end

  defp stable_clock?(_row), do: false

  defp clock_beta(_ordinal, expected) when expected <= 1, do: 0.4

  defp clock_beta(ordinal, expected) do
    frac = min((ordinal - 1) / max(expected - 1, 1), 1.0)
    0.2 + 0.35 * frac
  end

  defp blend_datetimes(a, b, beta) do
    ua = DateTime.to_unix(a)
    ub = DateTime.to_unix(b)
    DateTime.from_unix!(round(ua * (1 - beta) + ub * beta)) |> DateTime.truncate(:second)
  end

  defp clamp_after(dt, nil), do: dt

  defp clamp_after(dt, floor) do
    if DateTime.compare(dt, floor) == :lt, do: floor, else: dt
  end

  defp latest_of(dt, others) do
    Enum.reduce(others, dt, fn candidate, acc ->
      if DateTime.compare(candidate, acc) == :gt, do: candidate, else: acc
    end)
  end

  # How long they've been up versus how long they usually last before this
  # nap. `:past` means they are beyond their usual upper quartile (or the age
  # prior's upper bound) — overtiredness territory.
  defp wake_pressure(nil, _n_done, _expected, _last_nap, _stats, _now, _transition?), do: nil

  defp wake_pressure(last_wake, n_done, expected, last_nap, stats, now, transition?) do
    awake = max(DateTime.diff(now, last_wake, :second), 0)

    case wake_estimate(stats, n_done + 1, expected) do
      nil ->
        %{awake_seconds: awake, typical_seconds: nil, upper_seconds: nil, state: nil, source: nil}

      est ->
        %{typical: typical, range: range, source: source} =
          adjust_for_last_nap(est, last_nap, n_done, stats)

        range = range && widen_if(range, transition?)

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

  defp bedtime_prediction(child, today, stats, last_wake, n_done, typical, bias) do
    median_mins = stats.bedtime.median_minutes
    median_dt = median_mins && minutes_to_dt(child, today.date, median_mins)
    last_ww = wake_median(stats, :last)

    from_wake =
      if last_wake && last_ww && typical > 0 && n_done >= typical do
        DateTime.add(last_wake, round(last_ww), :second)
      end

    base =
      cond do
        median_dt && from_wake ->
          unix = div(DateTime.to_unix(median_dt) + DateTime.to_unix(from_wake), 2)
          at = DateTime.from_unix!(unix) |> DateTime.truncate(:second)
          %{at: at, source: :blended}

        median_dt ->
          %{at: median_dt, source: :history}

        from_wake ->
          %{at: from_wake, source: :blended}

        true ->
          nil
      end

    finish_bedtime(base, child, today, stats, n_done, typical, bias)
  end

  defp finish_bedtime(nil, _child, _today, _stats, _n_done, _typical, _bias), do: nil

  defp finish_bedtime(%{at: at} = base, child, today, stats, n_done, typical, bias) do
    biased = DateTime.add(at, bias, :second)
    {shifted, debt} = shift_for_nap_debt(biased, child, today, stats, n_done, typical)

    Map.merge(base, %{
      at: shifted,
      label: Child.local_clock(child, shifted),
      estimate?: true,
      shifted_by_seconds: debt
    })
  end

  # When the day's daytime sleep is running short of this child's norm, bring
  # bedtime earlier by half the deficit (capped), but never before 18:00 local.
  defp shift_for_nap_debt(at, child, today, stats, n_done, typical) do
    typ = stats.naps[:day_total_median]

    remaining =
      if is_integer(typical) and n_done < typical do
        (n_done + 1)..typical
        |> Enum.map(&(nap_median(stats, &1) || 0))
        |> Enum.sum()
      else
        0
      end

    done = closed_nap_seconds(today)
    deficit = if is_number(typ), do: typ - (done + remaining), else: 0

    if deficit > @nap_debt_threshold do
      earlier = min(round(deficit / 2), @max_bedtime_shift)
      floor = minutes_to_dt(child, today.date, @earliest_bedtime_minutes)
      shifted = at |> DateTime.add(-earlier, :second) |> clamp_after_floor(floor)
      {shifted, DateTime.diff(at, shifted, :second)}
    else
      {at, 0}
    end
  end

  defp clamp_after_floor(dt, floor) do
    if DateTime.compare(dt, floor) == :lt, do: floor, else: dt
  end

  defp rest_schedule(_child, _today, nil, _n_done, _typical, _stats, _bedtime, _now), do: []

  defp rest_schedule(_child, _today, _last, _n_done, 0, _stats, bedtime, _now),
    do: wrap_bed(bedtime)

  defp rest_schedule(child, today, last_wake, n_done, typical, stats, bedtime, now) do
    nap_ords =
      if is_integer(typical) and n_done < typical do
        Enum.to_list((n_done + 1)..typical)
      else
        []
      end

    {items, _cursor} =
      Enum.reduce(nap_ords, {[], last_wake}, fn ord, {acc, t} ->
        ww = round(wake_median(stats, ord, typical) || 0)
        nap_len = round(nap_median(stats, ord) || 0)

        start =
          child
          |> anchor_to_clock(add_seconds(t, ww), today, stats, ord, typical, t)
          |> latest_of([t, now])

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

  # Shrinkage blend of the child's own recency-weighted nap count and the age
  # prior; `0` only when we have neither.
  defp typical_nap_count(stats) do
    hist = stats.naps.count
    prior = Norms.typical_nap_count(stats[:age_days])

    blended =
      cond do
        is_number(hist[:median]) and is_integer(prior) ->
          w = hist.eff_n / (hist.eff_n + @blend_k)
          w * hist.median + (1 - w) * prior

        is_number(hist[:median]) ->
          hist.median

        is_integer(prior) ->
          prior * 1.0

        true ->
          0.0
      end

    round(blended)
  end

  # A shrinkage blend of the child's own (recency-weighted) wake window for this
  # ordinal and the age prior: `w = eff_n / (eff_n + @blend_k)`. Returns `nil`
  # only when there is neither history nor an age prior. The age prior is scaled
  # by `Norms.wake_window_position_factor/2` — short first window of the day,
  # long last one before bed — while the history side already carries position
  # via `by_ordinal`.
  defp wake_estimate(stats, ordinal, expected) do
    prior =
      stats[:age_days]
      |> Norms.wake_window_range()
      |> position_scaled_prior(ordinal, expected)

    blend_wake(wake_row(stats, ordinal), prior)
  end

  defp position_scaled_prior(nil, _ordinal, _expected), do: nil

  defp position_scaled_prior({lo, hi}, ordinal, expected) do
    f = Norms.wake_window_position_factor(ordinal, expected)
    {lo * f, hi * f}
  end

  # Shorten the window after a short nap, lengthen it a little after a long one:
  # `adj = clamp(nap_len / typical_nap_len, 0.7, 1.15)`, then never below the
  # age floor. `n_done` is 0 (last wake was the morning, not a nap) → no change.
  defp adjust_for_last_nap(est, nil, _n_done, _stats), do: est
  defp adjust_for_last_nap(est, _last_nap, 0, _stats), do: est

  defp adjust_for_last_nap(%{typical: t, range: range} = est, last_nap, n_done, stats) do
    floor = Norms.min_wake_window_seconds(stats[:age_days])

    adj =
      case nap_median(stats, n_done) do
        med when is_number(med) and med > 0 -> clamp(last_nap.seconds / med, 0.7, 1.15)
        _ -> 1.0
      end

    %{
      est
      | typical: max(t * adj, floor),
        range: scale_range(range, adj, floor)
    }
  end

  defp scale_range(nil, _adj, _floor), do: nil
  defp scale_range({lo, hi}, adj, floor), do: {max(lo * adj, floor), max(hi * adj, floor)}

  defp clamp(x, lo, hi), do: x |> max(lo) |> min(hi)

  defp blend_wake(%{median: med, eff_n: eff} = hist, {plo, phi}) when is_number(med) do
    prior_mid = (plo + phi) / 2
    w = eff / (eff + @blend_k)

    %{
      typical: w * med + (1 - w) * prior_mid,
      range: blend_wake_range(hist[:quartiles], {plo, phi}, w),
      source: wake_source(eff)
    }
  end

  defp blend_wake(%{median: med, quartiles: q}, nil) when is_number(med) do
    %{typical: med, range: q, source: :history}
  end

  defp blend_wake(_hist, {plo, phi}) do
    %{typical: (plo + phi) / 2, range: {plo, phi}, source: :age_prior}
  end

  defp blend_wake(_hist, nil), do: nil

  defp blend_wake_range({qlo, qhi}, {plo, phi}, w) do
    {w * qlo + (1 - w) * plo, w * qhi + (1 - w) * phi}
  end

  defp blend_wake_range(nil, {plo, phi}, _w), do: {plo, phi}

  defp wake_source(eff_n) when eff_n >= @history_source_eff_n, do: :history
  defp wake_source(eff_n) when eff_n < 1.0, do: :age_prior
  defp wake_source(_eff_n), do: :blended

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

  defp wake_median(stats, ordinal, expected) when is_integer(ordinal) do
    case wake_estimate(stats, ordinal, expected) do
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
