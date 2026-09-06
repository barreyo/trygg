defmodule Trygg.Reports.Norms do
  @moduledoc """
  Age-based priors used only as labelled fallbacks and sanity floors when a
  child's own history is too thin. The child's logged pattern always wins once
  there is enough of it.

  Sources (all population guidance, none of it a validated schedule):

    * Wake windows — no peer-reviewed table exists. The anchor points below are
      the overlap of the mainstream practitioner charts (Huckleberry, The Bump,
      Taking Cara Babies, Baby Sleep Science) reconciled with the structural
      findings in `docs/sleep-prediction-research.md`, and are interpolated
      linearly by age so the prediction has no step discontinuities. Ranges are
      deliberately wide; cues beat clocks. `wake_window_position_factor/2`
      captures that the first wake window of the day runs short and the last
      before bed runs long.
    * Nap count — `typical_nap_count/1` follows the widely published
      progression (4 → 3 → 2 → 1 across the first ~15 months); the 2→1 drop is
      readiness-driven, so the age boundary is only a prior.
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

  # {age_days, {low_minutes, high_minutes}} for the *midday* wake window,
  # linearly interpolated between neighbours. See the moduledoc.
  @wake_window_anchors [
    {10, {40, 60}},
    {21, {45, 70}},
    {42, {50, 85}},
    {70, {60, 100}},
    {98, {70, 115}},
    {120, {85, 135}},
    {150, {100, 150}},
    {180, {120, 170}},
    {240, {140, 195}},
    {300, {155, 210}},
    {365, {170, 235}},
    {455, {195, 260}},
    {545, {240, 320}},
    {730, {300, 360}},
    {1095, {300, 360}}
  ]

  @doc """
  `{low_seconds, high_seconds}` typical *midday* wake window for the child's
  age, interpolated between age anchors, or `nil` when age is unknown or past
  the infant range. Multiply by `wake_window_position_factor/2` for the first
  or last window of the day.
  """
  def wake_window_range(nil), do: nil

  def wake_window_range(age_days) when is_integer(age_days) and age_days >= 0 do
    {min_age, _} = hd(@wake_window_anchors)
    {max_age, _} = List.last(@wake_window_anchors)

    cond do
      age_days > max_age -> nil
      age_days <= min_age -> anchor_to_seconds(elem(hd(@wake_window_anchors), 1))
      true -> interpolate_wake_window(age_days)
    end
  end

  def wake_window_range(_), do: nil

  defp anchor_to_seconds({lo, hi}), do: {lo * 60, hi * 60}

  defp interpolate_wake_window(age_days) do
    [{a1, {lo1, hi1}}, {a2, {lo2, hi2}}] =
      @wake_window_anchors
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.find(fn [{a, _}, {b, _}] -> age_days >= a and age_days <= b end)

    f = (age_days - a1) / (a2 - a1)
    {round((lo1 + (lo2 - lo1) * f) * 60), round((hi1 + (hi2 - hi1) * f) * 60)}
  end

  @doc """
  Prior for how many naps a child of this age typically takes, or `nil` when
  age is unknown or past the age naps usually persist. The child's own logged
  count always wins once there is enough of it — this only seeds a prediction
  for a child with no nap history yet.
  """
  def typical_nap_count(nil), do: nil

  def typical_nap_count(age_days) when is_integer(age_days) and age_days >= 0 do
    cond do
      # < ~12 weeks: many short naps
      age_days < 84 -> 4
      # ~3–8 months: settling toward three, 3→2 transition in the tail
      age_days < 245 -> 3
      # ~8–15 months: two naps
      age_days < 450 -> 2
      # ~15 months–4 years: one midday nap
      age_days < 1460 -> 1
      true -> nil
    end
  end

  def typical_nap_count(_), do: nil

  @doc """
  Multiplier on `wake_window_range/1` for the `ordinal`-th wake window of a day
  expected to hold `expected` naps: the first window of the day runs short, the
  last before bed runs long, the rest sit near 1.0.
  """
  def wake_window_position_factor(ordinal, expected)
      when is_integer(ordinal) and is_integer(expected) and expected >= 1 do
    cond do
      expected == 1 -> 1.0
      ordinal <= 1 -> 0.82
      ordinal >= expected -> 1.2
      true -> 0.85 + 0.3 * ((ordinal - 1) / max(expected - 1, 1))
    end
  end

  def wake_window_position_factor(_ordinal, _expected), do: 1.0

  @doc "Shortest wake window worth predicting at this age, in seconds."
  def min_wake_window_seconds(nil), do: 20 * 60

  def min_wake_window_seconds(age_days) when is_integer(age_days) do
    cond do
      age_days < 84 -> 20 * 60
      age_days < 180 -> 45 * 60
      age_days < 365 -> 75 * 60
      true -> 120 * 60
    end
  end

  @doc "The most naps a day should ever be predicted to hold at this age."
  def max_naps(nil), do: 5

  def max_naps(age_days) when is_integer(age_days) do
    cond do
      age_days < 84 -> 6
      age_days < 180 -> 4
      age_days < 300 -> 3
      age_days < 545 -> 2
      true -> 1
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

  @doc """
  The longest gap, in days, that routine growth monitoring should leave
  between weight checks at the child's age.

  Weight (and length) are measured at every well-child visit. The CDC points
  parents at the AAP/Bright Futures periodicity schedule, which recommends
  visits at 3–5 days, by 1 month, then at 2, 4, 6, 9, 12, 15, 18, 24 and 30
  months, and once a year after that. Each bracket below is roughly the
  widest gap between two neighbouring visits in that span, smoothed to keep
  the nudge gentle rather than clinical. Age unknown falls back to a
  conservative 90 days.
  """
  def weight_check_interval_days(nil), do: 90

  def weight_check_interval_days(age_days) when is_integer(age_days) do
    cond do
      # birth → 3–5 days → 1 month
      age_days < 30 -> 21
      # 1 → 2 → 4 months
      age_days < 120 -> 42
      # 4 → 6 → 9 → 12 months
      age_days < 365 -> 90
      # 12 → 15 → 18 → 24 months
      age_days < 730 -> 120
      # 24 → 30 → 36 months, easing to annual
      age_days < 1825 -> 182
      true -> 365
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
