defmodule Trygg.Growth.Percentiles do
  @moduledoc """
  CDC 2000 infant (birth–36 months) weight-for-age and length-for-age
  percentiles, using the published LMS parameters, with the INTERGROWTH-21st
  preterm standard (`Trygg.Growth.PretermStandard`) for babies born early
  until they reach 64 weeks postmenstrual age.

  Charts are sex-specific (`:female` / `:male`). Returns `nil` when the child
  has no birth date, sex is `:unspecified`, age is outside 0–36 months, or the
  measurement is missing.

  Weight LMS values are in kilograms; length is in centimetres. Callers pass
  Trygg's canonical storage units (grams / centimetres).

  For babies born before 39+0 weeks — preterm or early term, see
  `Child.born_early?/1` — age is corrected (counted from the date they reached
  40+0 weeks) until they turn two. Clinicians usually only correct preterm
  babies; early term is included here on purpose.

  On corrected age, measurements up to 64+0 weeks postmenstrual age (about
  24 weeks corrected) are scored on the INTERGROWTH-21st preterm standard —
  its intended range, after which it hands over — and on CDC with corrected
  age after that (`handover_date/1`). The standard starts at 27+0 weeks;
  earlier than that everything returns `nil`. On actual age
  (`corrected: false`, or `Child.uncorrected/1`) the CDC charts are used from
  birth.

  Source: [CDC growth chart data files](https://www.cdc.gov/growthcharts/cdc-data-files.htm)
  (`wtageinf.csv`, `lenageinf.csv`).
  """

  alias Trygg.Families.Child
  alias Trygg.Growth.PretermStandard

  @type kind :: :weight | :length
  @type percentile :: pos_integer() | {:below, 1} | {:above, 99}

  @max_months 36.0
  @avg_days_per_month 30.4375
  @band_percentiles [5, 50, 95]

  # Inverse normal CDF at 0.05 / 0.50 / 0.95.
  @z_by_percentile %{
    5 => -1.6448536269514722,
    50 => 0.0,
    95 => 1.6448536269514722
  }

  @wtage_path Path.expand("../../../priv/cdc/wtageinf.csv", __DIR__)
  @lenage_path Path.expand("../../../priv/cdc/lenageinf.csv", __DIR__)
  @external_resource @wtage_path
  @external_resource @lenage_path

  @tables (
            to_f = fn s ->
              {f, _} = Float.parse(s)
              f
            end

            parse = fn path ->
              path
              |> File.read!()
              |> String.replace_prefix("\uFEFF", "")
              |> String.split(["\r\n", "\n", "\r"], trim: true)
              |> Enum.reduce(%{male: [], female: []}, fn line, acc ->
                case String.split(line, ",") do
                  ["Sex" | _] ->
                    acc

                  [sex, agemos, l, m, s | _] ->
                    key =
                      case sex do
                        "1" -> :male
                        "2" -> :female
                        _ -> nil
                      end

                    if key do
                      row = {to_f.(agemos), to_f.(l), to_f.(m), to_f.(s)}
                      Map.update!(acc, key, &[row | &1])
                    else
                      acc
                    end

                  _ ->
                    acc
                end
              end)
              |> Map.new(fn {sex, rows} ->
                {sex, rows |> Enum.reverse() |> Enum.sort_by(&elem(&1, 0))}
              end)
            end

            %{weight: parse.(@wtage_path), length: parse.(@lenage_path)}
          )

  @doc "Whether CDC infant charts can be drawn for this child."
  @spec available?(%Child{}) :: boolean()
  def available?(%Child{sex: sex, birth_date: %Date{}}) when sex in [:female, :male], do: true
  def available?(_), do: false

  @doc """
  Why percentiles are unavailable, or `nil` when they can be computed.

  `:unspecified_sex` and `:no_birth_date` are the cases the UI explains.
  `:before_preterm_chart` means a baby born very early is still younger than
  27 weeks postmenstrual age on `date` (defaulting to the child's local
  today), where no chart applies; see `first_date/1`.
  """
  @spec hint(%Child{}, Date.t() | nil) ::
          :unspecified_sex | :no_birth_date | :before_preterm_chart | nil
  def hint(child, date \\ nil)
  def hint(%Child{birth_date: nil}, _date), do: :no_birth_date
  def hint(%Child{sex: :unspecified}, _date), do: :unspecified_sex

  def hint(%Child{} = child, date) do
    date = date || Child.local_today(child)
    if Date.before?(date, first_date(child)), do: :before_preterm_chart
  end

  @doc """
  The first date corrected percentiles exist for: birth, or for a baby born
  before 27 weeks the day they reach 27+0 weeks, where the INTERGROWTH-21st
  preterm standard starts. `nil` without a birth date.
  """
  @spec first_date(%Child{}) :: Date.t() | nil
  def first_date(%Child{birth_date: nil}), do: nil

  def first_date(%Child{birth_date: dob, gestational_age_days: ga} = child) do
    if Child.born_early?(child),
      do: Date.add(dob, max(PretermStandard.range_days().first - ga, 0)),
      else: dob
  end

  @doc """
  The first date a child born early is scored on CDC in corrected mode, the
  day after they reach 64+0 weeks postmenstrual age. `nil` for term babies.
  """
  @spec handover_date(%Child{}) :: Date.t() | nil
  def handover_date(%Child{birth_date: %Date{} = dob, gestational_age_days: ga} = child) do
    if Child.born_early?(child), do: Date.add(dob, PretermStandard.range_days().last - ga + 1)
  end

  def handover_date(%Child{}), do: nil

  @doc """
  Which growth standard scores a measurement on `date`: `:intergrowth`,
  `:cdc`, or `nil` when none applies.
  """
  @spec standard_on(%Child{}, Date.t()) :: :intergrowth | :cdc | nil
  def standard_on(%Child{} = child, %Date{} = date) do
    case reference(child, :weight, date) do
      {:preterm, _sex, _days} -> :intergrowth
      {:lms, _lms} -> :cdc
      nil -> nil
    end
  end

  @doc """
  Names the standard(s) behind the percentile bands charted over
  `[from, to]`: `"CDC"`, `"INTERGROWTH-21st"`, or
  `"INTERGROWTH-21st → CDC"` when the window spans the handover.
  """
  @spec band_label(%Child{}, Date.t(), Date.t()) :: String.t() | nil
  def band_label(%Child{} = child, %Date{} = from, %Date{} = to) do
    if available?(child) do
      {start, stop} = curve_span(child, from, to)

      [start, stop]
      |> Enum.map(&standard_on(child, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map_join(" → ", &standard_name/1)
      |> case do
        "" -> nil
        label -> label
      end
    end
  end

  defp standard_name(:intergrowth), do: "INTERGROWTH-21st"
  defp standard_name(:cdc), do: "CDC"

  @doc """
  Footnote for the growth card, or `nil` when charts don't apply. Mentions the
  age correction while it's in effect on `date` (defaults to local today).
  """
  @spec source_label(%Child{}, Date.t() | nil) :: String.t() | nil
  def source_label(child, date \\ nil)

  def source_label(%Child{sex: sex} = child, date) when sex in [:female, :male] do
    chart =
      if sex == :female,
        do: "CDC 2000 infant charts (girls), birth–36 months",
        else: "CDC 2000 infant charts (boys), birth–36 months"

    if corrected?(child, date || Child.local_today(child)),
      do:
        "#{chart}, using corrected age (born at #{Child.gestation_label(child)}), with the " <>
          "INTERGROWTH-21st preterm standard until 64 weeks postmenstrual age",
      else: chart
  end

  def source_label(_child, _date), do: nil

  @doc """
  Whether percentiles on `date` use corrected rather than chronological age:
  the child was born before 39+0 weeks and is younger than two.
  """
  @spec corrected?(%Child{}, Date.t()) :: boolean()
  def corrected?(%Child{} = child, %Date{} = date), do: Child.corrects_age?(child, date)

  @doc "The 5th, 50th, and 95th percentile lines used on the charts."
  @spec band_percentiles() :: [5 | 50 | 95]
  def band_percentiles, do: @band_percentiles

  @doc """
  Integer percentile (1–99) of a canonical measurement, or a below/above
  marker. `date` defaults to the child's local today.
  """
  @spec percentile(%Child{}, kind, number | nil, Date.t() | nil) :: percentile() | nil
  def percentile(child, kind, value, date \\ nil)

  def percentile(_child, _kind, nil, _date), do: nil

  def percentile(%Child{} = child, kind, value, date)
      when is_number(value) and kind in [:weight, :length] do
    date = date || Child.local_today(child)

    child |> reference(kind, date) |> ref_zscore(kind, value) |> z_to_percentile()
  end

  @doc """
  Z-score (standard deviations from the median for age) of a canonical
  measurement, or `nil` when charts don't apply. Unlike `percentile/4` this is
  not clipped, so differences between two readings stay meaningful.

  Pass `corrected: boolean` to pin the age basis instead of choosing it from
  `date` — comparing two readings either side of the second birthday on
  different bases would show a jump that isn't growth.
  """
  @spec zscore(%Child{}, kind, number | nil, Date.t() | nil, keyword()) :: float() | nil
  def zscore(child, kind, value, date \\ nil, opts \\ [])

  def zscore(_child, _kind, nil, _date, _opts), do: nil

  def zscore(%Child{} = child, kind, value, date, opts)
      when is_number(value) and kind in [:weight, :length] do
    date = date || Child.local_today(child)

    child |> reference(kind, date, opts[:corrected]) |> ref_zscore(kind, value)
  end

  @doc "Integer percentile (or below/above marker) for a z-score."
  @spec percentile_from_z(float() | nil) :: percentile() | nil
  def percentile_from_z(z), do: z_to_percentile(z)

  @doc """
  Canonical value at an arbitrary z-score on `date`, or `nil`. Takes the same
  `:corrected` option as `zscore/5`.
  """
  @spec value_at_z(%Child{}, kind, float(), Date.t(), keyword()) :: float() | nil
  def value_at_z(%Child{} = child, kind, z, %Date{} = date, opts \\ [])
      when kind in [:weight, :length] and is_number(z) do
    child |> reference(kind, date, opts[:corrected]) |> ref_value(kind, z)
  end

  @doc "Formats `42` as `\"42nd\"`, `{:below, 1}` as `\"<1st\"`, `nil` as `nil`."
  @spec format_percentile(percentile() | nil) :: String.t() | nil
  def format_percentile(nil), do: nil
  def format_percentile({:below, 1}), do: "<1st"
  def format_percentile({:above, 99}), do: ">99th"

  def format_percentile(n) when is_integer(n) and n >= 1 and n <= 99 do
    "#{n}#{ordinal_suffix(n)}"
  end

  @doc """
  Canonical value (grams or centimetres) on a percentile curve at `date`.
  `percentile` is typically 5, 50, or 95.
  """
  @spec value_at(%Child{}, kind, pos_integer(), Date.t()) :: float() | nil
  def value_at(%Child{} = child, kind, percentile, %Date{} = date)
      when kind in [:weight, :length] and is_integer(percentile) do
    with z when is_float(z) <- z_for_percentile(percentile) do
      child |> reference(kind, date) |> ref_value(kind, z)
    end
  end

  @doc """
  Sampled `{date, canonical_value}` points along a percentile curve, clipped to
  `first_date/1` through 36 months and to `[from, to]`. For a child born early
  the curve steps where the preterm standard hands over to CDC at 64 weeks
  (`handover_date/1`).
  """
  @spec curve(%Child{}, kind, pos_integer(), Date.t(), Date.t()) :: [{Date.t(), float()}]
  def curve(%Child{} = child, kind, percentile, %Date{} = from, %Date{} = to)
      when kind in [:weight, :length] do
    if available?(child) do
      {start, stop} = curve_span(child, from, to)

      if Date.after?(start, stop) do
        []
      else
        days = max(Date.diff(stop, start), 1)
        step = max(div(days, 40), 1)

        dates =
          start
          |> Stream.iterate(&Date.add(&1, step))
          |> Stream.take_while(&(Date.compare(&1, stop) != :gt))
          |> Enum.to_list()

        dates = if rem(days, step) == 0, do: dates, else: dates ++ [stop]

        dates
        |> Enum.uniq()
        |> Enum.flat_map(fn date ->
          case value_at(child, kind, percentile, date) do
            nil -> []
            value -> [{date, value}]
          end
        end)
      end
    else
      []
    end
  end

  defp curve_span(%Child{birth_date: dob} = child, from, to) do
    first = first_date(child)
    start = if Date.before?(from, first), do: first, else: from
    stop = min_date(to, shift_years(dob, 3))
    {start, stop}
  end

  defp min_date(a, b), do: if(Date.before?(a, b), do: a, else: b)

  defp shift_years(%Date{year: year, month: month, day: day}, n) do
    new_year = year + n
    last = Date.days_in_month(%Date{year: new_year, month: month, day: 1})
    Date.new!(new_year, month, min(day, last))
  end

  # The growth reference a measurement on `date` is scored against:
  # `{:lms, lms}` for the CDC infant charts, `{:preterm, sex, pma_days}` for
  # the INTERGROWTH-21st preterm standard, or `nil` when neither applies.
  defp reference(child, kind, date, corrected \\ nil)

  defp reference(%Child{sex: sex} = child, kind, date, corrected) when sex in [:female, :male] do
    case age_basis(child, date, corrected) do
      {:months, months} ->
        with %{} = lms <- interpolate_lms(@tables[kind][sex], months), do: {:lms, lms}

      {:postmenstrual, days} ->
        if days in PretermStandard.range_days(), do: {:preterm, sex, days}

      nil ->
        nil
    end
  end

  defp reference(_child, _kind, _date, _corrected), do: nil

  # `corrected` is `nil` to pick the basis from `date`, or a boolean to force
  # it (still only for children born early). Corrected age up to 64+0 weeks
  # is postmenstrual age on the preterm standard.
  defp age_basis(%Child{birth_date: nil}, _date, _corrected), do: nil

  defp age_basis(%Child{birth_date: dob} = child, %Date{} = date, corrected) do
    corrected? =
      if is_nil(corrected),
        do: corrected?(child, date),
        else: corrected and Child.born_early?(child)

    term = Child.term_date(child)
    start = if corrected?, do: term, else: dob
    months = Date.diff(date, start) / @avg_days_per_month

    cond do
      Date.before?(date, dob) ->
        nil

      corrected? and Date.before?(date, handover_date(child)) ->
        {:postmenstrual, Child.postmenstrual_age_days(child, date)}

      months > @max_months ->
        nil

      true ->
        {:months, months}
    end
  end

  defp ref_zscore(nil, _kind, _value), do: nil

  defp ref_zscore({:lms, %{l: l, m: m, s: s}}, kind, value),
    do: z_score(to_lms_unit(kind, value), l, m, s)

  defp ref_zscore({:preterm, sex, days}, kind, value),
    do: PretermStandard.zscore(sex, kind, days, to_lms_unit(kind, value))

  defp ref_value(nil, _kind, _z), do: nil

  defp ref_value({:lms, %{l: l, m: m, s: s}}, kind, z) do
    with raw when is_number(raw) <- value_from_z(z, l, m, s), do: from_lms_unit(kind, raw)
  end

  defp ref_value({:preterm, sex, days}, kind, z) do
    with raw when is_number(raw) <- PretermStandard.value_at_z(sex, kind, days, z),
         do: from_lms_unit(kind, raw)
  end

  defp interpolate_lms(_rows, months) when months < 0 or months > @max_months, do: nil

  defp interpolate_lms(rows, months) do
    {first_age, _, _, _} = hd(rows)
    {last_age, last_l, last_m, last_s} = List.last(rows)

    cond do
      months < first_age ->
        nil

      months >= last_age ->
        %{l: last_l, m: last_m, s: last_s}

      true ->
        {a, b} = neighbors(rows, months)
        {a_age, a_l, a_m, a_s} = a
        {b_age, b_l, b_m, b_s} = b
        t = (months - a_age) / (b_age - a_age)

        %{
          l: lerp(a_l, b_l, t),
          m: lerp(a_m, b_m, t),
          s: lerp(a_s, b_s, t)
        }
    end
  end

  defp neighbors([a, b | _rest], months) when months <= elem(b, 0), do: {a, b}
  defp neighbors([_a, b | rest], months), do: neighbors([b | rest], months)

  defp lerp(a, b, t), do: a + (b - a) * t

  defp z_score(x, l, m, s) when x > 0 and s > 0 and m > 0 do
    if abs(l) < 1.0e-8 do
      :math.log(x / m) / s
    else
      (:math.pow(x / m, l) - 1.0) / (l * s)
    end
  end

  defp z_score(_x, _l, _m, _s), do: nil

  defp value_from_z(z, l, m, s) do
    raw =
      if abs(l) < 1.0e-8 do
        m * :math.exp(s * z)
      else
        inner = 1.0 + l * s * z
        if inner > 0, do: m * :math.pow(inner, 1.0 / l)
      end

    if is_number(raw) and raw > 0, do: raw
  end

  defp z_for_percentile(p) when is_map_key(@z_by_percentile, p), do: @z_by_percentile[p]

  defp z_for_percentile(p) when is_integer(p) and p > 0 and p < 100 do
    # z = √2 · erf⁻¹(2p − 1)
    :math.sqrt(2.0) * erfinv(2.0 * (p / 100.0) - 1.0)
  end

  defp z_for_percentile(_), do: nil

  defp z_to_percentile(nil), do: nil

  defp z_to_percentile(z) do
    pct = 100.0 * (0.5 * (1.0 + :math.erf(z / :math.sqrt(2.0))))

    cond do
      pct < 1.0 -> {:below, 1}
      pct > 99.0 -> {:above, 99}
      true -> round(pct)
    end
  end

  defp to_lms_unit(:weight, grams), do: grams / 1000.0
  defp to_lms_unit(:length, cm), do: cm * 1.0

  defp from_lms_unit(:weight, kg), do: kg * 1000.0
  defp from_lms_unit(:length, cm), do: cm * 1.0

  defp ordinal_suffix(n) when rem(n, 100) in [11, 12, 13], do: "th"

  defp ordinal_suffix(n) do
    case rem(n, 10) do
      1 -> "st"
      2 -> "nd"
      3 -> "rd"
      _ -> "th"
    end
  end

  # Winitzki approximation of erf⁻¹, plenty accurate for 1st–99th.
  defp erfinv(x) when abs(x) >= 1.0, do: nil

  defp erfinv(x) do
    a = 0.147
    ln = :math.log(1.0 - x * x)
    inner = 2.0 / (:math.pi() * a) + ln / 2.0
    sign = if x < 0, do: -1.0, else: 1.0
    sign * :math.sqrt(:math.sqrt(inner * inner - ln / a) - inner)
  end
end
