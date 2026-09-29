defmodule Trygg.Growth.PretermStandard do
  @moduledoc """
  INTERGROWTH-21st International Postnatal Growth Standards for Preterm
  Infants: weight and length by postmenstrual age (weeks since the last
  menstrual period: gestational age at birth plus age since birth), 27+0 to
  64+0 weeks.

  `Trygg.Growth.Percentiles` uses this for a baby born early whose
  measurement falls before their 40-week date, where the CDC infant charts
  (which start at a full-term birth) don't apply.

  The published z-score tables give each measure at −3 … +3 SD for every
  exact week. Between weeks each SD line is interpolated linearly. Between SD
  lines the z-score is interpolated linearly in log(value), which tracks the
  published centile tables to within their rounding (about 2 percentile
  points); beyond ±3 SD the outer segment is extended. Values are kilograms
  and centimetres, like the CDC LMS tables.

  Source: Villar J, et al. Postnatal growth standards for preterm infants:
  the Preterm Postnatal Follow-up Study of the INTERGROWTH-21st Project.
  Lancet Glob Health 2015;3:e681–91. Tables © University of Oxford,
  transcribed into `priv/intergrowth/`.
  """

  @type sex :: :female | :male
  @type kind :: :weight | :length

  @first_week 27
  @last_week 64
  @z_lines [-3.0, -2.0, -1.0, 0.0, 1.0, 2.0, 3.0]

  @files for kind <- [:weight, :length],
             {sex, name} <- [male: "boys", female: "girls"],
             do:
               {{kind, sex},
                Path.expand(
                  "../../../priv/intergrowth/preterm_#{kind}_#{name}_zscores.csv",
                  __DIR__
                )}

  for {_key, path} <- @files, do: @external_resource(path)

  # %{{kind, sex} => %{week => [7 SD-line values]}}
  @tables Map.new(@files, fn {key, path} ->
            rows =
              path
              |> File.read!()
              |> String.split(["\r\n", "\n"], trim: true)
              |> Enum.drop(1)
              |> Map.new(fn line ->
                [week | values] = String.split(line, ",")

                {String.to_integer(week),
                 Enum.map(values, fn v -> v |> Float.parse() |> elem(0) end)}
              end)

            {key, rows}
          end)

  @doc "Postmenstrual ages covered, in days (27+0 to 64+0 weeks)."
  @spec range_days() :: Range.t()
  def range_days, do: (@first_week * 7)..(@last_week * 7)

  @doc """
  Z-score of `value` (kg or cm) at `pma_days` postmenstrual age, or `nil`
  outside 27–64 weeks.
  """
  @spec zscore(sex, kind, integer, number) :: float | nil
  def zscore(sex, kind, pma_days, value) when is_number(value) and value > 0 do
    with [_ | _] = lines <- lines_at(sex, kind, pma_days) do
      logs = Enum.map(lines, &:math.log/1)
      {{z0, v0}, {z1, v1}} = segment(Enum.zip(@z_lines, logs), :math.log(value))
      z0 + (:math.log(value) - v0) / (v1 - v0) * (z1 - z0)
    end
  end

  def zscore(_sex, _kind, _pma_days, _value), do: nil

  @doc """
  The value (kg or cm) at z-score `z` for `pma_days`, or `nil` outside 27–64
  weeks.
  """
  @spec value_at_z(sex, kind, integer, number) :: float | nil
  def value_at_z(sex, kind, pma_days, z) when is_number(z) do
    with [_ | _] = lines <- lines_at(sex, kind, pma_days) do
      logs = Enum.map(lines, &:math.log/1)
      {{z0, v0}, {z1, v1}} = segment(Enum.zip(@z_lines, logs), z, :z)
      :math.exp(v0 + (z - z0) / (z1 - z0) * (v1 - v0))
    end
  end

  # The seven SD-line values at a (fractional) week, interpolated between the
  # neighbouring exact weeks.
  defp lines_at(sex, kind, pma_days) when is_integer(pma_days) do
    table = @tables[{kind, sex}]

    cond do
      is_nil(table) ->
        nil

      pma_days < @first_week * 7 or pma_days > @last_week * 7 ->
        nil

      true ->
        week = min(div(pma_days, 7), @last_week - 1)
        t = (pma_days - week * 7) / 7

        Enum.zip_with(table[week], table[week + 1], fn a, b -> a + (b - a) * t end)
    end
  end

  # The pair of adjacent `{z, log_value}` points bracketing `x`, falling back
  # to the outer segment so values beyond ±3 SD extrapolate.
  defp segment(points, x, by \\ :value) do
    pairs = Enum.chunk_every(points, 2, 1, :discard)
    pick = fn {z, v} -> if by == :z, do: z, else: v end

    Enum.find(pairs, List.last(pairs), fn [_lo, hi] -> x <= pick.(hi) end)
    |> List.to_tuple()
  end
end
