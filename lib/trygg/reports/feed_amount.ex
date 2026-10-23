defmodule Trygg.Reports.FeedAmount do
  @moduledoc """
  Nudges the next-feed estimate by how much the last feeding episode was.

  A bigger bottle tends to buy a longer gap, a small one a shorter gap — but
  only for some babies, some of the time. So the nudge is fitted per child and
  has to prove itself before it is used:

    * Each interval is expressed relative to its period (day or night): gap as
      a multiple of the period's median gap, volume as a multiple of the
      period's median volume. That removes the "night feeds are bigger and
      further apart" confound without splitting a small sample in two.
    * A line through `(1, 1)` — a typical feed gives the typical gap — is fitted
      with least squares; the slope is clamped to `0..1` (proportional at most).
    * A walk-forward backtest predicts every interval from only the intervals
      before it, with and without the line. The line is used only when it
      beats the plain median by `@min_gain` over at least `@min_tests` tests.

  Pure: takes the chronological intervals `%{seconds, ml, period}` (one per
  gap between feeding episodes, `ml` being the volume of the episode that
  starts it) and returns `nil` whenever it has nothing trustworthy to add.
  """

  alias Trygg.Reports.Stats

  # A period needs this many intervals to have its own medians.
  @min_group 3
  # Intervals required before the first backtest prediction.
  @min_train 8
  @min_tests 5
  # Fraction of absolute error the line must save over the median.
  @min_gain 0.03
  @max_slope 1.0
  # A feed never moves the estimate by more than this factor either way.
  @min_factor 0.5
  @max_factor 1.5

  @doc """
  Estimates the gap after an episode of `ml` in `period`.

  Returns `%{seconds, baseline, typical_ml, range: {lo, hi}}` — all seconds
  except `typical_ml` — or `nil` when the amount carries no usable signal.
  """
  def estimate(points, period, ml)
      when is_list(points) and period in [:day, :night] and is_number(ml) and ml > 0 do
    points = Enum.filter(points, &(&1.ml > 0))

    with true <- length(points) >= @min_train + @min_tests,
         %{slope: slope} = model when slope > 0 <- fit(points),
         true <- beats_median?(points) do
      seconds = predict(model, period, ml)
      residuals = Enum.map(points, &(&1.seconds - predict(model, &1.period, &1.ml)))
      {lo, hi} = Stats.quartiles(residuals)

      %{
        seconds: seconds,
        baseline: model.gaps[period],
        typical_ml: model.mls[period],
        range: {max(seconds + lo, 0.0), seconds + hi}
      }
    else
      _ -> nil
    end
  end

  def estimate(_points, _period, _ml), do: nil

  defp fit(points) do
    gaps = group_medians(points, & &1.seconds)
    mls = group_medians(points, & &1.ml)

    {sxx, sxy} =
      Enum.reduce(points, {0.0, 0.0}, fn p, {sxx, sxy} ->
        x = p.ml / mls[p.period] - 1
        y = p.seconds / gaps[p.period] - 1
        {sxx + x * x, sxy + x * y}
      end)

    slope = if sxx == 0, do: 0.0, else: sxy / sxx
    %{gaps: gaps, mls: mls, slope: slope |> max(0.0) |> min(@max_slope)}
  end

  defp group_medians(points, fun) do
    overall = points |> Enum.map(fun) |> Stats.median()
    by_period = Enum.group_by(points, & &1.period, fun)

    Map.new([:day, :night], fn period ->
      values = Map.get(by_period, period, [])
      {period, if(length(values) >= @min_group, do: Stats.median(values), else: overall)}
    end)
  end

  defp predict(model, period, ml) do
    factor = 1 + model.slope * (ml / model.mls[period] - 1)
    model.gaps[period] * (factor |> max(@min_factor) |> min(@max_factor))
  end

  defp beats_median?(points) do
    {model_error, median_error, tests} =
      Enum.reduce(@min_train..(length(points) - 1)//1, {0.0, 0.0, 0}, fn i, {em, eb, n} ->
        {train, [test | _]} = Enum.split(points, i)
        model = fit(train)
        guess = predict(model, test.period, test.ml)

        {em + abs(test.seconds - guess), eb + abs(test.seconds - model.gaps[test.period]), n + 1}
      end)

    tests >= @min_tests and model_error < median_error * (1 - @min_gain)
  end
end
