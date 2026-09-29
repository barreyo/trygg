defmodule Trygg.Growth.Velocity do
  @moduledoc """
  Weight gain between measurements, expressed the way clinicians read it:
  grams per day/week, movement in z-score (percentile crossing), and the gain
  that would have kept the child on their previous percentile.

  Also the two newborn checks from standard guidance: more than 10% loss in
  the first week, and regaining birth weight by about day 14. Birth weight is
  the measurement dated on the child's `birth_date`.

  Pure: takes the child and its measurements (any order).
  """

  alias Trygg.Families.Child
  alias Trygg.Growth.Measurement
  alias Trygg.Growth.Percentiles
  alias Trygg.Reports.Norms

  # Prefer a prior reading 1–5 weeks back so the rate isn't dominated by
  # day-to-day scale noise; accept ≥ 5 days apart as a fallback.
  @preferred_span 7..35
  @min_span 5
  # One "major centile band" (e.g. 50th → 25th) in z units.
  @drop_z 0.67
  @drop_min_days 14
  @loss_window_days 7
  @newborn_window_days 60

  def summarize(%Child{} = child, measurements) when is_list(measurements) do
    weights = weights(child, measurements)
    latest = List.last(weights)
    prior = latest && pick_prior(weights, latest)

    %{
      available?: not is_nil(prior),
      latest: latest,
      prior: prior,
      velocity: prior && velocity(child, latest, prior),
      newborn: newborn(child, weights),
      prompt_birth_weight?: prompt_birth_weight?(child, weights)
    }
  end

  ## Weights ---------------------------------------------------------------

  defp weights(child, measurements) do
    measurements
    |> Enum.filter(&is_number(&1.weight_g))
    |> Enum.map(fn %Measurement{} = m ->
      %{id: m.id, date: local_date(child, m.measured_at), grams: m.weight_g * 1.0}
    end)
    |> Enum.sort_by(&{&1.date, &1.id}, fn {d1, i1}, {d2, i2} ->
      case Date.compare(d1, d2) do
        :lt -> true
        :gt -> false
        :eq -> i1 <= i2
      end
    end)
  end

  defp local_date(%Child{timezone: tz}, %DateTime{} = dt) do
    dt |> DateTime.shift_zone!(tz) |> DateTime.to_date()
  end

  defp pick_prior(weights, latest) do
    earlier =
      weights
      |> Enum.reject(&(&1.id == latest.id))
      |> Enum.map(&Map.put(&1, :span, Date.diff(latest.date, &1.date)))
      |> Enum.filter(&(&1.span > 0))

    preferred = Enum.filter(earlier, &(&1.span in @preferred_span))

    if preferred != [] do
      Enum.max_by(preferred, & &1.span)
    else
      earlier |> Enum.filter(&(&1.span >= @min_span)) |> Enum.min_by(& &1.span, fn -> nil end)
    end
  end

  ## Velocity ---------------------------------------------------------------

  defp velocity(child, latest, prior) do
    days = Date.diff(latest.date, prior.date)
    gain = latest.grams - prior.grams
    per_day = gain / days

    # Score both readings on the latest one's age basis, so a child born early
    # turning two (corrected → chronological age) doesn't read as a drop.
    basis = [corrected: Percentiles.corrected?(child, latest.date)]
    z_now = Percentiles.zscore(child, :weight, latest.grams, latest.date, basis)
    z_prev = Percentiles.zscore(child, :weight, prior.grams, prior.date, basis)
    delta_z = if is_number(z_now) and is_number(z_prev), do: z_now - z_prev

    expected =
      if is_number(z_prev) do
        case Percentiles.value_at_z(child, :weight, z_prev, latest.date, basis) do
          nil -> nil
          held -> held - prior.grams
        end
      end

    guide = Norms.weight_gain_g_per_day(Norms.corrected_age_days(child, latest.date))

    %{
      days: days,
      gain_g: gain,
      g_per_day: per_day,
      g_per_week: per_day * 7,
      z_now: z_now,
      z_prev: z_prev,
      delta_z: delta_z,
      percentile_now: Percentiles.percentile_from_z(z_now),
      percentile_prev: Percentiles.percentile_from_z(z_prev),
      expected_gain_g: expected,
      percentile_drop?: is_number(delta_z) and delta_z <= -@drop_z and days >= @drop_min_days,
      guide_g_per_day: guide,
      guide_status: guide_status(per_day, guide)
    }
  end

  defp guide_status(_per_day, nil), do: nil

  defp guide_status(per_day, {lo, hi}) do
    cond do
      per_day < lo -> :below
      per_day > hi -> :above
      true -> :within
    end
  end

  ## Newborn ----------------------------------------------------------------

  defp newborn(%Child{birth_date: nil}, _weights), do: nil

  defp newborn(%Child{birth_date: dob} = child, weights) do
    birth = Enum.find(weights, &(Date.compare(&1.date, dob) == :eq))
    latest = List.last(weights)
    age_days = latest && Norms.age_days(child, latest.date)

    if birth != nil and latest != nil and latest.id != birth.id and is_integer(age_days) and
         age_days <= @newborn_window_days do
      after_birth = Enum.reject(weights, &(&1.id == birth.id))

      lowest =
        after_birth
        |> Enum.filter(&(Date.diff(&1.date, dob) <= @loss_window_days))
        |> Enum.min_by(& &1.grams, fn -> nil end)

      loss_pct = lowest && (birth.grams - lowest.grams) / birth.grams * 100.0

      regained =
        after_birth
        |> Enum.filter(&(&1.grams >= birth.grams))
        |> List.first()

      regained_day = regained && Date.diff(regained.date, dob)
      regain_by = Norms.regain_by_day()

      %{
        birth_grams: birth.grams,
        lowest_grams: lowest && lowest.grams,
        loss_pct: loss_pct,
        loss_flag?: is_number(loss_pct) and loss_pct > Norms.newborn_loss_flag_pct(),
        regained_on: regained && regained.date,
        regained_day: regained_day,
        regained_by_14?: is_integer(regained_day) and regained_day <= regain_by,
        # Only say "not yet" once we have a reading after day 14 that's still low.
        regain_overdue?: is_nil(regained) and Date.diff(latest.date, dob) > regain_by,
        latest_pct_of_birth: latest.grams / birth.grams * 100.0
      }
    end
  end

  defp prompt_birth_weight?(%Child{birth_date: nil}, _weights), do: false

  defp prompt_birth_weight?(%Child{birth_date: dob} = child, weights) do
    age = Norms.age_days(child, Child.local_today(child))

    is_integer(age) and age <= @newborn_window_days and
      not Enum.any?(weights, &(Date.compare(&1.date, dob) == :eq))
  end
end
