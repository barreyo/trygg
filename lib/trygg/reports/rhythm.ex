defmodule Trygg.Reports.Rhythm do
  @moduledoc """
  The child's "typical day" expressed as clock positions — the usual morning
  wake, bedtime and nap windows — together with today's sleep so far and where
  the clock is right now. Feeds the Home screen's rhythm dial
  (`TryggWeb.RhythmComponents.rhythm_dial/1`).

  Pure. Built from the same `%Trygg.Reports.Day{}` list as the rest of
  `Trygg.Reports`, over complete days only (today is excluded from the typical
  figures so a half-finished day can't drag them around).

  Every clock field is **minutes from local midnight**. Bedtimes and nap ends
  that land after midnight run past `1440` on purpose, so an arc drawn from
  them sweeps the short way round instead of wrapping.

  Shape:

      %{
        ready?: boolean,        # enough history for a real wake/bed estimate
        wake_minutes: number,   # 0..1440
        bed_minutes: number,    # > wake_minutes, may exceed 1440
        naps: [%{ordinal: pos_integer, start_minutes: number, end_minutes: number}],
        today: [%{start_minutes: number, end_minutes: number, running?: boolean}],
        now_minutes: number     # 0..1440
      }
  """

  alias Trygg.Families.Child
  alias Trygg.Reports.Day
  alias Trygg.Reports.Norms
  alias Trygg.Reports.Stats

  # Same floor the rest of `Trygg.Reports` uses before it trusts a statistic.
  @min_sample 3
  # Fallbacks while history is too thin — a plain, unalarming default day.
  @default_wake_minutes 7 * 60
  @default_bed_minutes 19 * 60 + 30

  @doc """
  Builds the rhythm map for `today_day` from `days` (oldest first, today
  included or not — it's filtered out of the typical figures either way).
  """
  def summarize(%Child{} = child, days, %Day{} = today_day, %DateTime{} = now)
      when is_list(days) do
    prior = Enum.reject(days, &(&1.date == today_day.date))

    wake = clock_median(child, prior, & &1.morning_wake, false)
    bed = clock_median(child, prior, & &1.bedtime, true)
    naps = typical_naps(child, prior, latest_date(days))

    wake_minutes = wake || @default_wake_minutes
    bed_minutes = normalize_bed(bed || @default_bed_minutes, wake_minutes)

    %{
      ready?: not is_nil(wake) and not is_nil(bed),
      wake_minutes: wake_minutes,
      bed_minutes: bed_minutes,
      naps: naps,
      today: today_segments(today_day),
      now_minutes: now_minutes(child, now)
    }
  end

  # Bedtime is stored past midnight when it's an early-morning time, so it
  # always sorts after the wake it precedes; nudge it a full day on if a
  # near-midnight median still lands before wake.
  defp normalize_bed(bed, wake) when bed <= wake, do: bed + 24 * 60
  defp normalize_bed(bed, _wake), do: bed

  defp clock_median(_child, [], _getter, _bedtime?), do: nil

  defp clock_median(child, days, getter, bedtime?) do
    minutes =
      days
      |> Enum.map(getter)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&minutes_from_midnight(child, &1, bedtime?))

    if length(minutes) >= @min_sample, do: Stats.median(minutes), else: nil
  end

  defp typical_naps(child, days, latest_date) do
    age_days = latest_date && Norms.corrected_age_days(child, latest_date)
    max_ordinal = Norms.max_naps(age_days)

    days
    |> Enum.flat_map(& &1.naps)
    |> Enum.reject(& &1.running?)
    |> Enum.group_by(& &1.ordinal)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {ordinal, naps} ->
      if length(naps) >= @min_sample and ordinal <= max_ordinal do
        start = Stats.median(Enum.map(naps, &minutes_from_midnight(child, &1.start, false)))
        duration = Stats.median(Enum.map(naps, & &1.seconds))
        [%{ordinal: ordinal, start_minutes: start, end_minutes: start + duration / 60}]
      else
        []
      end
    end)
  end

  defp today_segments(%Day{sleep_segments: segments}) do
    Enum.map(segments, fn s ->
      %{
        start_minutes: s.offset / 60,
        end_minutes: (s.offset + s.seconds) / 60,
        running?: s.running?
      }
    end)
  end

  defp latest_date([]), do: nil
  defp latest_date(days), do: List.last(days).date

  defp now_minutes(%Child{timezone: tz}, now) do
    local = DateTime.shift_zone!(now, tz)
    local.hour * 60 + local.minute + local.second / 60
  end

  defp minutes_from_midnight(%Child{timezone: tz}, %DateTime{} = dt, bedtime?) do
    local = DateTime.shift_zone!(dt, tz)
    minutes = local.hour * 60 + local.minute
    if bedtime? and minutes < 12 * 60, do: minutes + 24 * 60, else: minutes
  end
end
