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
