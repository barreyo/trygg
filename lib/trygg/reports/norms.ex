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
    * Feeds per day and volume per feed — Johns Hopkins Medicine / Stanford
      Children's "Feeding Guide for the First Year" (1 mo: 2–4 oz × 6–8;
      2 mo: 5–6 oz × 5–6; 3–5 mo: 6–7 oz × 5–6) and CDC "How Much and How
      Often to Feed Infant Formula" (first days: 1–2 oz every 2–3 h, 8–12
      feeds; 6–12 mo: 5–6 feeds of formula or solids). Both stress that
      feeding should follow the baby's cues, not a schedule; these are shown
      as "typical for age" context only.
    * Wet diapers — AAP "Signs of Dehydration in Infants & Children" (fewer
      than six wet diapers a day; no urine for six-plus hours) and standard
      newborn day-of-life ramps (roughly one wet diaper per day of life until
      day five).
    * Weight gain — Merck Manual (20–30 g/day for the first few months) and
      Mayo Clinic (about 20 g/day around 4 months, 10 g/day or less by 6
      months); regain birth weight by ~day 14; >10% loss in week one is a flag.
    * Energy — standard-strength formula and mature breast milk both sit at
      about 20 kcal per fl oz (≈0.67 kcal/ml) (AAP; Merck Manual). Used only to
      turn logged bottle volume into an estimated calorie figure.
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
  Typical bottle pattern for the child's age: `%{feeds_per_day: {lo, hi},
  ml_per_feed: {lo, hi} | nil}`, or `nil` when age is unknown or past the
  first year. Population context only — cues decide when and how much.
  """
  def typical_feeds(nil), do: nil

  def typical_feeds(age_days) when is_integer(age_days) do
    cond do
      age_days < 14 -> %{feeds_per_day: {8, 12}, ml_per_feed: {30, 60}}
      age_days < 45 -> %{feeds_per_day: {6, 8}, ml_per_feed: {60, 120}}
      age_days < 75 -> %{feeds_per_day: {5, 6}, ml_per_feed: {150, 180}}
      age_days < 180 -> %{feeds_per_day: {5, 6}, ml_per_feed: {180, 210}}
      # Solids start to share the load; the sources give no per-bottle volume.
      age_days < 365 -> %{feeds_per_day: {5, 6}, ml_per_feed: nil}
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

  @doc "Approximate energy density of formula / breast milk, in kcal per ml."
  def kcal_per_ml, do: 0.67

  @doc "Estimated kilocalories in `ml` of formula or breast milk."
  def estimated_kcal(ml) when is_number(ml), do: ml * kcal_per_ml()
  def estimated_kcal(_ml), do: nil

  @doc "Footnote explaining how calories are estimated."
  def kcal_note do
    "Calories are estimated from bottle volume at 20 kcal per fl oz (0.67 kcal/ml), " <>
      "the standard for formula and mature breast milk. Actual content varies."
  end
end
