defmodule Trygg.Reports.Diapers do
  @moduledoc """
  Diaper output over a window of `%Trygg.Reports.Day{}`: wet and dirty counts
  per day, the child's own baseline, today's pace against that baseline at the
  same time of day, and the AAP hydration floors (fewer than six wet diapers a
  day; no urine for six-plus hours).

  "Wet" counts `pee` and `mixed`; "dirty" counts `poo` and `mixed`.

  Pure: takes the child, the days (oldest first, today last) and `now`.
  """

  alias Trygg.Families.Child
  alias Trygg.Reports.Day
  alias Trygg.Reports.Norms
  alias Trygg.Reports.Stats

  @min_days 3
  @baseline_days 7
  # Don't judge today's pace until this much of the day has gone by.
  @pace_min_elapsed 8 * 3600
  @pace_ratio 0.5
  # Only raise "no wet diaper" when someone has logged something recently —
  # otherwise the quiet is just nobody logging.
  @activity_window 6 * 3600

  def summarize(%Child{} = child, days, %DateTime{} = now) when is_list(days) do
    now = DateTime.truncate(now, :second)
    per_day = Enum.map(days, &day_row/1)

    complete =
      per_day |> Enum.filter(&(&1.complete? and &1.total > 0)) |> Enum.take(-@baseline_days)

    ready? = length(complete) >= @min_days

    today_day = List.last(days)
    today_date = if today_day, do: today_day.date, else: Child.local_today(child)
    age_days = Norms.age_days(child, today_date)
    min_wet = Norms.min_wet_diapers(age_days)

    all_diapers = days |> Enum.flat_map(& &1.diapers) |> Enum.sort_by(& &1.at, DateTime)
    last_wet = all_diapers |> Enum.filter(&wet?/1) |> List.last()
    last_wet_at = last_wet && last_wet.at
    dry_seconds = last_wet_at && max(DateTime.diff(now, last_wet_at, :second), 0)

    baseline = %{
      wet: Stats.sample(Enum.map(complete, & &1.wet), ready?),
      dirty: Stats.sample(Enum.map(complete, & &1.dirty), ready?),
      days: length(complete)
    }

    today = today_pace(today_day, days, ready?)
    yesterday = yesterday_row(per_day, today_date)

    %{
      ready?: ready?,
      min_days: @min_days,
      per_day: per_day,
      baseline: baseline,
      today: today,
      yesterday: yesterday,
      last_wet_at: last_wet_at,
      dry_seconds: dry_seconds,
      min_wet: min_wet,
      max_dry_seconds: Norms.max_dry_hours() * 3600,
      flags: flags(days, today, yesterday, baseline, dry_seconds, min_wet, age_days, now)
    }
  end

  ## Rows -------------------------------------------------------------------

  defp day_row(%Day{} = day) do
    wet = Enum.count(day.diapers, &wet?/1)
    dirty = Enum.count(day.diapers, &dirty?/1)

    %{
      date: day.date,
      wet: wet,
      dirty: dirty,
      total: length(day.diapers),
      complete?: not day.now?
    }
  end

  defp wet?(%{data: %{"kind" => kind}}), do: kind in ["pee", "mixed"]
  defp wet?(_), do: false

  defp dirty?(%{data: %{"kind" => kind}}), do: kind in ["poo", "mixed"]
  defp dirty?(_), do: false

  defp yesterday_row(per_day, today_date) do
    Enum.find(per_day, &(Date.compare(&1.date, Date.add(today_date, -1)) == :eq))
  end

  ## Today's pace -----------------------------------------------------------

  defp today_pace(nil, _days, _ready?), do: nil

  defp today_pace(%Day{now?: false} = day, _days, _ready?) do
    row = day_row(day)
    %{wet: row.wet, dirty: row.dirty, elapsed_seconds: nil, expected_wet_by_now: nil}
  end

  defp today_pace(%Day{now_offset: offset} = day, days, ready?) do
    row = day_row(day)

    prior =
      days
      |> Enum.reject(&(&1.date == day.date))
      |> Enum.filter(&(not &1.now? and &1.diapers != []))
      |> Enum.take(-@baseline_days)

    expected =
      if ready? and prior != [] do
        prior
        |> Enum.map(fn d -> Enum.count(d.diapers, &(wet?(&1) and &1.offset <= offset)) end)
        |> Stats.median()
      end

    %{wet: row.wet, dirty: row.dirty, elapsed_seconds: offset, expected_wet_by_now: expected}
  end

  ## Flags ------------------------------------------------------------------

  defp flags(days, today, yesterday, baseline, dry_seconds, min_wet, age_days, now) do
    [
      no_wet_flag(days, dry_seconds, age_days, now),
      low_pace_flag(today),
      low_day_flag(yesterday, baseline, min_wet, age_days)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp no_wet_flag(days, dry_seconds, age_days, now) when is_integer(dry_seconds) do
    newborn_first_days? = is_integer(age_days) and age_days < 2

    cond do
      dry_seconds < Norms.max_dry_hours() * 3600 -> nil
      newborn_first_days? -> nil
      not recently_active?(days, now) -> nil
      true -> :no_wet_6h
    end
  end

  defp no_wet_flag(_days, _dry, _age, _now), do: nil

  defp recently_active?(days, now) do
    since = DateTime.add(now, -@activity_window, :second)

    Enum.any?(days, fn day ->
      Enum.any?(day.feeds ++ day.diapers, &(DateTime.compare(&1.at, since) != :lt))
    end)
  end

  defp low_pace_flag(%{elapsed_seconds: elapsed, expected_wet_by_now: expected, wet: wet})
       when is_integer(elapsed) and elapsed >= @pace_min_elapsed and is_number(expected) and
              expected >= 2 do
    if wet < expected * @pace_ratio, do: :low_wet_pace
  end

  defp low_pace_flag(_), do: nil

  defp low_day_flag(%{wet: wet, total: total}, baseline, min_wet, age_days)
       when total > 0 and wet < min_wet do
    old_enough? = is_nil(age_days) or age_days >= 1

    below_baseline? =
      case baseline.wet.median do
        nil -> true
        med -> wet <= med - 2
      end

    if old_enough? and below_baseline?, do: :low_wet_day
  end

  defp low_day_flag(_, _, _, _), do: nil
end
