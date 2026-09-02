defmodule Trygg.Reports.Norms do
  @moduledoc """
  Age-based priors used only as labelled fallbacks and sanity floors when a
  child's own history is too thin. The child's logged pattern always wins once
  there is enough of it.

  Sources (all population guidance, none of it a validated schedule):

    * Wake windows — no peer-reviewed table exists; ranges below are the
      overlap of commonly published charts (e.g. ParentData 2024, Baby Sleep
      Science 2024, betteroo 2025) and are deliberately wide. Cues beat clocks.
    * Intake — AAP / HealthyChildren "Amount and Schedule of Formula Feedings"
      (~150 ml/kg/day early, easing to 120–150 by 2–6 months and 100–120 once
      solids start); Better Health Victoria; Merck Manual.
    * Wet diapers — AAP "Signs of Dehydration in Infants & Children" (fewer
      than six wet diapers a day; no urine for six-plus hours) and standard
      newborn day-of-life ramps (roughly one wet diaper per day of life until
      day five).
    * Weight gain — Merck Manual (20–30 g/day for the first few months) and
      Mayo Clinic (about 20 g/day around 4 months, 10 g/day or less by 6
      months); regain birth weight by ~day 14; >10% loss in week one is a flag.
  """

  alias Trygg.Families.Child

  @doc "Whole days since birth on `date`, or `nil` without a birth date."
  def age_days(%Child{birth_date: nil}, _date), do: nil

  def age_days(%Child{birth_date: dob}, %Date{} = date) do
    days = Date.diff(date, dob)
    if days < 0, do: nil, else: days
  end

  @doc """
  `{low_seconds, high_seconds}` typical wake window for the child's age, or
  `nil` when age is unknown or beyond the infant range.
  """
  def wake_window_range(nil), do: nil

  def wake_window_range(age_days) when is_integer(age_days) do
    minutes =
      cond do
        age_days < 28 -> {45, 60}
        age_days < 90 -> {60, 90}
        age_days < 150 -> {75, 120}
        age_days < 210 -> {120, 180}
        age_days < 300 -> {150, 210}
        age_days < 390 -> {180, 240}
        age_days < 570 -> {180, 270}
        age_days < 730 -> {240, 360}
        age_days < 1095 -> {300, 360}
        true -> nil
      end

    case minutes do
      {lo, hi} -> {lo * 60, hi * 60}
      nil -> nil
    end
  end

  @doc """
  `{low, high}` ml per kg per day guide for bottle-fed infants, or `nil` once
  solids carry most of the intake (after the first year) or age is unknown.
  """
  def intake_ml_per_kg(nil), do: nil

  def intake_ml_per_kg(age_days) when is_integer(age_days) do
    cond do
      age_days < 60 -> {150, 180}
      age_days < 180 -> {120, 150}
      age_days < 365 -> {100, 120}
      true -> nil
    end
  end

  @doc """
  The fewest wet diapers a healthy infant is expected to produce in a full
  day at this age. Day one is the first 24 hours of life.
  """
  def min_wet_diapers(nil), do: 6

  def min_wet_diapers(age_days) when is_integer(age_days) do
    cond do
      age_days < 1 -> 1
      age_days < 2 -> 2
      age_days < 3 -> 3
      age_days < 4 -> 4
      age_days < 5 -> 5
      true -> 6
    end
  end

  @doc "Hours without a wet diaper that warrant attention for an infant."
  def max_dry_hours, do: 6

  @doc """
  `{low, high}` expected grams gained per day for the child's age, or `nil`
  when unknown or past the first year.
  """
  def weight_gain_g_per_day(nil), do: nil

  def weight_gain_g_per_day(age_days) when is_integer(age_days) do
    cond do
      age_days < 14 -> nil
      age_days < 90 -> {20, 30}
      age_days < 180 -> {15, 25}
      age_days < 365 -> {8, 15}
      true -> nil
    end
  end

  @doc "Percent of birth weight lost in week one that is worth mentioning."
  def newborn_loss_flag_pct, do: 10.0

  @doc "Day of life by which birth weight is usually regained."
  def regain_by_day, do: 14
end
