defmodule Trygg.Sleep.AgeGuide do
  @moduledoc """
  What a typical day of sleep looks like at each age, as ranges, from
  *Precious Little Sleep* (Alexis Dubief). Where `Trygg.Sleep.Schedules` builds a
  day for 3 months and up from the Taking Cara Babies guides, this is the
  second opinion that also covers the newborn months and up to about three
  years: how many naps, how long they run, how long to stay awake, bedtime, and
  how many hours of night and total sleep.

  Wide ranges are the point. Babies vary far more than any chart, so
  `compare/2` only says whether this child's own numbers sit inside, below or
  above the range, never that something is wrong.

  Ages are corrected days. Durations are minutes, times minutes after local
  midnight, and sleep totals hours.
  """

  # The day shape by age band. `between` is the usual gap between naps, `before_bed`
  # the wake window before bedtime.
  @bands [
    %{
      id: :birth_6w,
      label: "Birth to 6 weeks",
      from_days: 0,
      naps: {4, 8},
      nap: {15, 240},
      between: {45, 60},
      before_bed: {60, 240},
      bedtime: {21 * 60, 23 * 60},
      night_hours: {8, 14},
      total_hours: {14, 18}
    },
    %{
      id: :six_weeks_3m,
      label: "6 weeks to 3 months",
      from_days: 42,
      naps: {3, 5},
      nap: {30, 120},
      between: {60, 105},
      before_bed: {60, 120},
      bedtime: {20 * 60, 23 * 60},
      night_hours: {8, 13},
      total_hours: {11, 15}
    },
    %{
      id: :three_6m,
      label: "3 to 6 months",
      from_days: 91,
      naps: {3, 3},
      nap: {60, 120},
      between: {120, 120},
      before_bed: {120, 180},
      bedtime: {19 * 60, 21 * 60},
      night_hours: {9, 12},
      total_hours: {12, 14}
    },
    %{
      id: :six_9m,
      label: "6 to 9 months",
      from_days: 182,
      naps: {3, 3},
      nap: {60, 120},
      between: {120, 180},
      before_bed: {180, 180},
      bedtime: {18 * 60 + 30, 20 * 60 + 30},
      night_hours: {9, 12},
      total_hours: {12, 14}
    },
    %{
      id: :nine_12m,
      label: "9 to 12 months",
      from_days: 274,
      naps: {2, 3},
      nap: {60, 120},
      between: {180, 180},
      before_bed: {240, 240},
      bedtime: {18 * 60 + 30, 20 * 60},
      night_hours: {10, 12},
      total_hours: {12, 14}
    },
    %{
      id: :twelve_18m,
      label: "12 to 18 months",
      from_days: 365,
      naps: {1, 2},
      nap: {60, 120},
      between: {180, 180},
      before_bed: {240, 300},
      bedtime: {19 * 60, 20 * 60},
      night_hours: {10, 12},
      total_hours: {12, 14}
    },
    %{
      id: :eighteen_36m,
      label: "18 months to 3 years",
      from_days: 548,
      naps: {1, 1},
      nap: {60, 120},
      between: nil,
      before_bed: {240, 360},
      bedtime: {19 * 60, 20 * 60},
      night_hours: {10, 12},
      total_hours: {11, 14}
    }
  ]

  # The month-by-month wake-time chart: how long to stay awake before a nap
  # (shortest early in the day, longest before bed), how long naps run, and how
  # many a day. For 12–18 months the wake time depends on whether they're on one nap or two.
  @wake_times [
    %{
      from_days: 0,
      label: "Birth to 6 weeks",
      wake: {30, 60},
      nap: {15, 240},
      naps: {4, 8}
    },
    %{from_days: 42, label: "6 weeks to 3 months", wake: {45, 105}, nap: {30, 120}, naps: {3, 5}},
    %{from_days: 91, label: "4 months", wake: {60, 120}, nap: {30, 120}, naps: {3, 4}},
    %{from_days: 122, label: "5 months", wake: {75, 150}, nap: {30, 120}, naps: {3, 3}},
    %{from_days: 152, label: "6 months", wake: {90, 180}, nap: {45, 120}, naps: {3, 3}},
    %{from_days: 182, label: "7 months", wake: {105, 210}, nap: {45, 120}, naps: {2, 3}},
    %{from_days: 213, label: "8 months", wake: {120, 210}, nap: {60, 120}, naps: {2, 3}},
    %{from_days: 243, label: "9 to 12 months", wake: {120, 240}, nap: {60, 120}, naps: {2, 2}},
    %{from_days: 365, label: "12 to 18 months", wake: {180, 360}, nap: {60, 180}, naps: {1, 2}},
    %{from_days: 548, label: "18 months and up", wake: {300, 300}, nap: {60, 180}, naps: {0, 1}}
  ]

  # Hours of night sleep after which the night gets too long for the day, and
  # the guide's rule of thumb for the last wake window: 1.3–1.5 times any other.
  @last_window_factor {1.3, 1.5}

  @doc "The day-shape bands, youngest first."
  def bands, do: @bands

  @doc "The month-by-month wake-time rows, youngest first."
  def wake_times, do: @wake_times

  @doc "The band for a corrected age in days (`nil` without an age)."
  def band(age_days) when is_integer(age_days) and age_days >= 0,
    do: @bands |> Enum.filter(&(&1.from_days <= age_days)) |> List.last()

  def band(_), do: nil

  @doc "The wake-time row for a corrected age in days (`nil` without an age)."
  def wake_time(age_days) when is_integer(age_days) and age_days >= 0,
    do: @wake_times |> Enum.filter(&(&1.from_days <= age_days)) |> List.last()

  def wake_time(_), do: nil

  @doc "The multiples of the usual wake window that the stretch before bed should be, as `{min, max}`."
  def last_window_factor, do: @last_window_factor

  @doc """
  `compare(band, stats)` lines up a child's own numbers with a band. `stats` is
  `%{naps: avg naps a day, nap_minutes: typical nap length, night_hours,
  total_hours, bedtime: minutes after midnight}` with `nil` for what isn't known.

  Returns a list of `%{metric, label, value, range, verdict}` for the metrics
  that have a value, where `verdict` is `:within`, `:below` or `:above`. The
  naps and bedtime ranges carry a little slack, since a day or two either side
  isn't a pattern.
  """
  def compare(nil, _stats), do: []

  def compare(band, stats) do
    [
      line(:naps, "Naps a day", stats[:naps], band.naps, 0.5),
      line(:nap_minutes, "Typical nap", stats[:nap_minutes], band.nap, 5),
      line(:night_hours, "Night sleep", stats[:night_hours], band.night_hours, 0.25),
      line(:total_hours, "Total sleep", stats[:total_hours], band.total_hours, 0.25),
      line(:bedtime, "Bedtime", stats[:bedtime], band.bedtime, 15)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp line(_metric, _label, nil, _range, _slack), do: nil

  defp line(metric, label, value, {lo, hi}, slack) do
    verdict =
      cond do
        value < lo - slack -> :below
        value > hi + slack -> :above
        true -> :within
      end

    %{metric: metric, label: label, value: value, range: {lo, hi}, verdict: verdict}
  end

  @doc """
  The stats `compare/2` takes, from an `Trygg.Reports.Insights.summarize/5` map
  (`totals`, `naps`, `bedtime`): medians over the days in the window, or `nil`
  where there isn't enough history yet.
  """
  def stats_from(%{ready?: false}), do: %{}

  def stats_from(insights) do
    nap_minutes =
      insights.naps.by_ordinal
      |> Enum.map(& &1.median)
      |> Enum.filter(&is_number/1)
      |> then(fn
        [] -> nil
        medians -> Enum.sum(medians) / length(medians) / 60
      end)

    %{
      naps: insights.naps.count.median,
      nap_minutes: nap_minutes,
      night_hours: hours(insights.totals.night.median),
      total_hours: hours(insights.totals.total.median),
      bedtime: insights.bedtime && insights.bedtime.median_minutes
    }
  end

  defp hours(nil), do: nil
  defp hours(seconds), do: seconds / 3600
end
