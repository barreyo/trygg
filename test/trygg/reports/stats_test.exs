defmodule Trygg.Reports.StatsTest do
  use ExUnit.Case, async: true

  alias Trygg.Reports.Stats

  test "median handles odd, even and empty lists" do
    assert Stats.median([]) == nil
    assert Stats.median([3, 1, 2]) == 2.0
    assert Stats.median([4, 1, 3, 2]) == 2.5
  end

  test "iqr and quartiles need four values" do
    assert Stats.iqr([1, 2, 3]) == nil
    assert Stats.quartiles([1, 2, 3]) == nil
    assert Stats.iqr([1, 2, 3, 4, 5, 6, 7, 8]) == 3.5
    assert {2.75, 6.25} = Stats.quartiles([1, 2, 3, 4, 5, 6, 7, 8])
  end

  test "mad is scaled to estimate the standard deviation" do
    assert Stats.mad([1, 2]) == nil
    assert_in_delta Stats.mad([1, 2, 3, 4, 5]), 1.4826, 0.0001
  end

  test "robust_z uses the floor when the baseline is flat" do
    flat = [5, 5, 5, 5, 5, 5, 5]
    assert Stats.robust_z(7, flat, 1.0) == 2.0
    assert Stats.robust_z(7, [5, 5], 1.0) == nil
    assert Stats.robust_z(nil, flat, 1.0) == nil
  end

  test "sample returns nils when not ready" do
    assert %{n: 0, median: nil} = Stats.sample([1, 2, 3], false)
    assert %{n: 3, median: 2.0, mean: 2.0} = Stats.sample([1, nil, 2, 3])
  end

  test "slope is the least-squares gradient per index" do
    assert Stats.slope([1]) == nil
    assert_in_delta Stats.slope([0, 2, 4, 6]), 2.0, 1.0e-9
    assert_in_delta Stats.slope([5, 5, 5]), 0.0, 1.0e-9
    assert_in_delta Stats.slope([0, 2, 3], [0, 4, 6]), 2.0, 1.0e-9
    assert Stats.slope([0, 1], [1]) == nil
  end
end
