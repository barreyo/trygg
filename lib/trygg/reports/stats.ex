defmodule Trygg.Reports.Stats do
  @moduledoc """
  Small, robust descriptive statistics shared by the report modules.

  Everything here favours medians and interquartile ranges over means and
  standard deviations, because a handful of odd days (a sick night, a missed
  log) should not swing a baby's "usual".
  """

  @doc """
  A `%{n, median, mean, iqr}` sample summary. Returns an all-`nil` sample
  when `ready?` is false or the list is empty. `nil` values are dropped.
  """
  def sample(values, ready? \\ true)

  def sample(_values, false), do: %{n: 0, median: nil, mean: nil, iqr: nil}

  def sample(values, true) do
    values = Enum.reject(values, &is_nil/1)

    %{
      n: length(values),
      median: median(values),
      mean: mean(values),
      iqr: iqr(values)
    }
  end

  @doc "Median of a list of numbers, or `nil` for an empty list."
  def median([]), do: nil

  def median(list) do
    sorted = Enum.sort(list)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1 do
      Enum.at(sorted, mid) * 1.0
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2.0
    end
  end

  @doc "Arithmetic mean, or `nil` for an empty list."
  def mean([]), do: nil
  def mean(list), do: Enum.sum(list) / length(list)

  @doc "Interquartile range; `nil` for fewer than four values."
  def iqr(list) when length(list) < 4, do: nil

  def iqr(list) do
    sorted = Enum.sort(list)
    percentile(sorted, 0.75) - percentile(sorted, 0.25)
  end

  @doc "Linear-interpolated percentile `p` (0..1) of an already sorted list."
  def percentile([], _p), do: nil

  def percentile(sorted, p) do
    n = length(sorted)
    idx = p * (n - 1)
    lo = floor(idx)
    hi = ceil(idx)
    a = Enum.at(sorted, lo)
    b = Enum.at(sorted, hi)
    a + (b - a) * (idx - lo)
  end

  @doc "`{p25, p75}` of a list, or `nil` for fewer than four values."
  def quartiles(list) when length(list) < 4, do: nil

  def quartiles(list) do
    sorted = Enum.sort(list)
    {percentile(sorted, 0.25), percentile(sorted, 0.75)}
  end

  @doc """
  Weighted quantile `p` (0..1) of `values`, each carrying the matching weight
  in `weights`. Pairs with a non-positive or non-numeric weight are dropped.

  Uses the "cumulative weight at the centre of each point's mass" convention,
  linearly interpolated between neighbouring points and clamped at the ends —
  so with equal weights it matches `percentile/2` closely and stays smooth as
  weights change. `nil` when nothing is left after filtering.
  """
  def weighted_quantile(values, weights, p)
      when is_list(values) and is_list(weights) and is_number(p) do
    pairs =
      values
      |> Enum.zip(weights)
      |> Enum.filter(fn {v, w} -> is_number(v) and is_number(w) and w > 0 end)
      |> Enum.sort_by(&elem(&1, 0))

    case pairs do
      [] ->
        nil

      [{v, _}] ->
        v * 1.0

      _ ->
        total = pairs |> Enum.map(&elem(&1, 1)) |> Enum.sum()

        {points, _} =
          Enum.map_reduce(pairs, 0.0, fn {v, w}, acc ->
            {{(acc + w / 2) / total, v * 1.0}, acc + w}
          end)

        interpolate_points(points, p)
    end
  end

  defp interpolate_points(points, p) do
    {first_c, first_v} = hd(points)
    {last_c, last_v} = List.last(points)

    cond do
      p <= first_c ->
        first_v

      p >= last_c ->
        last_v

      true ->
        [{c1, v1}, {c2, v2}] =
          points
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.find(fn [{a, _}, {b, _}] -> p >= a and p <= b end)

        v1 + (v2 - v1) * (p - c1) / (c2 - c1)
    end
  end

  @doc "Weighted median — `weighted_quantile/3` at `p = 0.5`."
  def weighted_median(values, weights), do: weighted_quantile(values, weights, 0.5)

  @doc """
  Kish effective sample size for a set of weights: `(Σw)² / Σw²`. Equals the
  count when the weights are equal and shrinks as they grow lopsided. `0.0`
  when no positive weight is left.
  """
  def effective_n(weights) when is_list(weights) do
    ws = Enum.filter(weights, &(is_number(&1) and &1 > 0))

    case ws do
      [] ->
        0.0

      ws ->
        sum = Enum.sum(ws)
        sum_sq = ws |> Enum.map(&(&1 * &1)) |> Enum.sum()
        sum * sum / sum_sq
    end
  end

  @doc """
  Median absolute deviation, scaled by 1.4826 so it estimates the standard
  deviation for normal data. `nil` for fewer than three values.
  """
  def mad(list) when length(list) < 3, do: nil

  def mad(list) do
    med = median(list)
    1.4826 * median(Enum.map(list, &abs(&1 - med)))
  end

  @doc """
  How many robust standard deviations `value` sits from the baseline's median.

  `floor` is the smallest spread we are willing to believe: when the baseline
  is unusually flat (MAD near zero) we use `floor` instead so a single tiny
  change is not reported as a huge z. Returns `nil` when the baseline is too
  small.
  """
  def robust_z(_value, baseline, _floor) when length(baseline) < 3, do: nil

  def robust_z(value, baseline, floor) when is_number(value) do
    med = median(baseline)
    spread = max(mad(baseline) || 0.0, floor)

    if spread <= 0, do: nil, else: (value - med) / spread
  end

  def robust_z(_value, _baseline, _floor), do: nil

  @doc "Ordinary least squares slope of `ys` against their index, or `nil`."
  def slope(ys) when length(ys) < 2, do: nil

  def slope(ys) do
    n = length(ys)
    xs = Enum.to_list(0..(n - 1))
    sum_x = Enum.sum(xs)
    sum_y = Enum.sum(ys)
    sum_xy = xs |> Enum.zip(ys) |> Enum.reduce(0, fn {x, y}, acc -> acc + x * y end)
    sum_x2 = Enum.reduce(xs, 0, fn x, acc -> acc + x * x end)
    denom = n * sum_x2 - sum_x * sum_x

    if denom == 0, do: 0.0, else: (n * sum_xy - sum_x * sum_y) / denom
  end
end
