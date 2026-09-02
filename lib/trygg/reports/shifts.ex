defmodule Trygg.Reports.Shifts do
  @moduledoc """
  Change detection on a child's own baseline.

  Compares the last few *complete* days against the two weeks before them
  using a robust z-score (median / MAD with an absolute floor). This is
  deliberately not a "sleep regression" predictor — population data show no
  reliable age-pinned regressions — it simply says "this is different from
  your usual" once the difference is both statistically and practically large.

  Also surfaces the one growth signal with real evidence behind it: Lampl &
  Johnson (Sleep, 2011) found bursts of roughly +4.5 h sleep and/or +3 sleep
  bouts a day for about two days preceded measurable length growth by 0–4
  days. When the last day or two look like that, `growth_burst.active?` is true.
  """

  alias Trygg.Reports.Stats

  @recent_days 3
  @baseline_days 14
  @min_baseline 7
  @z_threshold 2.0
  @burst_days 2
  @burst_min_extra_sleep 2 * 3600
  @burst_iqr_factor 1.5
  @burst_extra_naps 2
  @burst_feed_pct 20.0

  @doc """
  `days` oldest first, today last. `feeding` is the `Trygg.Reports.Feeding`
  summary (its `per_day` rows are used for the feed shift and burst volume).
  """
  def summarize(days, feeding \\ nil) when is_list(days) do
    complete = Enum.reject(days, & &1.now?)
    {baseline, recent} = split(complete)
    ready? = Enum.count(baseline, &(&1.total_sleep_seconds > 0)) >= @min_baseline

    feed_rows = (feeding && feeding.per_day) || []
    feed_baseline = rows_for(feed_rows, baseline)
    feed_recent = rows_for(feed_rows, recent)

    %{
      ready?: ready?,
      min_baseline: @min_baseline,
      baseline_days: length(baseline),
      recent_days: length(recent),
      sleep: if(ready?, do: sleep_findings(baseline, recent), else: []),
      feeding: if(ready?, do: feed_findings(feed_baseline, feed_recent), else: []),
      growth_burst: growth_burst(ready?, baseline, recent, feed_baseline, feed_recent)
    }
  end

  defp split(complete) do
    recent = Enum.take(complete, -@recent_days)
    rest = Enum.drop(complete, -length(recent))
    baseline = Enum.take(rest, -@baseline_days)
    {baseline, recent}
  end

  defp rows_for(rows, days) do
    dates = MapSet.new(days, & &1.date)
    Enum.filter(rows, &MapSet.member?(dates, &1.date))
  end

  ## Sleep -----------------------------------------------------------------

  defp sleep_findings(_baseline, []), do: []

  defp sleep_findings(baseline, recent) do
    [
      finding(
        :night_wakings,
        baseline,
        recent,
        &length(&1.night_wakings),
        floor: 1.0,
        min_delta: 1.0
      ),
      finding(
        :overnight_sleep,
        Enum.filter(baseline, &(&1.overnight_sleep_seconds > 0)),
        Enum.filter(recent, &(&1.overnight_sleep_seconds > 0)),
        & &1.overnight_sleep_seconds,
        floor: 45 * 60,
        min_delta: 45 * 60
      ),
      finding(
        :total_sleep,
        Enum.filter(baseline, &(&1.total_sleep_seconds > 0)),
        Enum.filter(recent, &(&1.total_sleep_seconds > 0)),
        & &1.total_sleep_seconds,
        floor: 45 * 60,
        min_delta: 45 * 60
      ),
      finding(:naps, baseline, recent, &length(&1.naps), floor: 1.0, min_delta: 1.0)
    ]
    |> Enum.reject(&is_nil/1)
  end

  ## Feeding ---------------------------------------------------------------

  defp feed_findings(baseline, recent) do
    baseline = Enum.filter(baseline, &(&1.count > 0))
    recent = Enum.filter(recent, &(&1.count > 0))

    if length(baseline) >= @min_baseline and recent != [] do
      base_ml = Stats.median(Enum.map(baseline, & &1.ml)) || 0

      [
        finding(:feeds, baseline, recent, & &1.count, floor: 1.0, min_delta: 1.0),
        finding(:feed_ml, baseline, recent, & &1.ml,
          floor: base_ml * 0.1,
          min_delta: base_ml * 0.15
        )
      ]
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  ## Shared finding builder -------------------------------------------------

  defp finding(_metric, baseline, recent, _fun, _opts)
       when length(baseline) < @min_baseline or recent == [],
       do: nil

  defp finding(metric, baseline, recent, fun, opts) do
    base_values = Enum.map(baseline, fun)
    recent_values = Enum.map(recent, fun)
    base_med = Stats.median(base_values)
    recent_med = Stats.median(recent_values)
    z = Stats.robust_z(recent_med, base_values, Keyword.fetch!(opts, :floor))
    delta = recent_med - base_med

    if is_number(z) and abs(z) >= @z_threshold and abs(delta) >= Keyword.fetch!(opts, :min_delta) do
      %{
        metric: metric,
        direction: if(delta > 0, do: :up, else: :down),
        baseline_median: base_med,
        recent_median: recent_med,
        delta: delta,
        z: z,
        baseline_n: length(base_values),
        recent_n: length(recent_values)
      }
    end
  end

  ## Growth burst ----------------------------------------------------------

  defp growth_burst(false, _b, _r, _fb, _fr), do: %{active?: false}
  defp growth_burst(_ready, _b, [], _fb, _fr), do: %{active?: false}

  defp growth_burst(true, baseline, recent, feed_baseline, feed_recent) do
    sleep_base = baseline |> Enum.map(& &1.total_sleep_seconds) |> Enum.filter(&(&1 > 0))
    nap_base = Enum.map(baseline, &length(&1.naps))
    last = Enum.take(recent, -@burst_days)

    sleep_med = Stats.median(sleep_base) || 0
    sleep_iqr = Stats.iqr(sleep_base) || 0
    sleep_bar = sleep_med + max(@burst_min_extra_sleep, @burst_iqr_factor * sleep_iqr)
    nap_med = Stats.median(nap_base) || 0

    sleep_days = Enum.count(last, &(&1.total_sleep_seconds >= sleep_bar))
    nap_days = Enum.count(last, &(length(&1.naps) >= nap_med + @burst_extra_naps))
    latest = List.last(last)

    feed_pct =
      with base when base != [] <- Enum.filter(feed_baseline, &(&1.count > 0)),
           recent_rows when recent_rows != [] <- Enum.filter(feed_recent, &(&1.count > 0)),
           base_ml when is_number(base_ml) and base_ml > 0 <-
             Stats.median(Enum.map(base, & &1.ml)) do
        last_ml = recent_rows |> Enum.take(-@burst_days) |> Enum.map(& &1.ml) |> Stats.mean()
        (last_ml - base_ml) / base_ml * 100.0
      else
        _ -> nil
      end

    active? = sleep_days >= 1 or nap_days >= 1

    %{
      active?: active?,
      sleep_days: sleep_days,
      nap_days: nap_days,
      extra_sleep_seconds: latest.total_sleep_seconds - sleep_med,
      extra_naps: length(latest.naps) - nap_med,
      feed_pct: feed_pct,
      feed_up?: is_number(feed_pct) and feed_pct >= @burst_feed_pct,
      on: latest.date
    }
  end

  @doc "Human labels for a finding's metric."
  def metric_label(:night_wakings), do: "Night wakings"
  def metric_label(:overnight_sleep), do: "Night stretch"
  def metric_label(:total_sleep), do: "Total sleep"
  def metric_label(:naps), do: "Naps per day"
  def metric_label(:feeds), do: "Feeds per day"
  def metric_label(:feed_ml), do: "Volume per day"
  def metric_label(other), do: other |> to_string() |> String.replace("_", " ")

  @doc "Whether a metric is a duration in seconds (vs a count or volume)."
  def duration_metric?(metric), do: metric in [:overnight_sleep, :total_sleep]
end
