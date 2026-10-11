defmodule Trygg.Sleep.ApproachesTest do
  use ExUnit.Case, async: true

  alias Trygg.Sleep.{Approaches, Plan}

  defp habits(fed, measured), do: %{week: %{fed_to_sleep: fed, measured: measured}}
  defp falling(level), do: %{this_week: %{mean_level: level}, weeks: []}

  test "under two months it's the tools, not a plan" do
    assert %{suggested: :tools} = Approaches.recommend(%{age_days: 40})
    assert %{suggested: :tools} = Approaches.recommend(%{age_days: nil})
  end

  test "from two months the book starts gradual" do
    assert %{suggested: :swap} = Approaches.recommend(%{age_days: 80})
  end

  test "after a gradual plan that ended, from four months the next step is SLIP" do
    plans = [%Plan{definition: :swap, status: :stopped}]
    assert %{suggested: :slip} = Approaches.recommend(%{age_days: 130, plans: plans})
    # Not old enough for SLIP yet: still a SWAP.
    assert %{suggested: :swap} = Approaches.recommend(%{age_days: 100, plans: plans})
    # A plan that's still running or a different plan doesn't count.
    assert %{suggested: :swap} =
             Approaches.recommend(%{
               age_days: 130,
               plans: [%Plan{definition: :swap, status: :active}]
             })
  end

  describe "baby type" do
    test "a baby often fed to sleep is a sucker, whatever the scale says" do
      assert Approaches.baby_type(habits(6, 10), falling(2.0)) == :sucker
      assert Approaches.baby_type(habits(2, 10), falling(2.0)) == :cuddler
    end

    test "feeds need enough sleeps with a feed before them" do
      assert Approaches.baby_type(habits(4, 4), nil) == nil
    end

    test "otherwise the sliding scale decides" do
      assert Approaches.baby_type(nil, falling(2.5)) == :cuddler
      assert Approaches.baby_type(nil, falling(4.2)) == :motion
      assert Approaches.baby_type(nil, falling(7.5)) == :independent
      assert Approaches.baby_type(nil, nil) == nil
    end

    test "falls back to the latest week with data" do
      weeks = [%{mean_level: 4.0}, %{mean_level: nil}]
      assert Approaches.baby_type(nil, %{this_week: %{mean_level: nil}, weeks: weeks}) == :motion
    end
  end

  test "the variant fits the type" do
    rec = fn habits, falling, age ->
      Approaches.recommend(%{age_days: age, habits: habits, falling_asleep: falling})
    end

    assert %{variant: :pull_out, type: :sucker} = rec.(habits(8, 10), nil, 90)
    assert %{variant: :chair, type: :cuddler} = rec.(nil, falling(2.0), 90)
    assert %{variant: :jiggle, type: :motion} = rec.(nil, falling(4.0), 90)
    assert %{variant: :pat, type: :motion} = rec.(nil, falling(4.0), 200)
    assert %{variant: :fuss_it_out} = rec.(nil, falling(7.0), 90)
    assert %{variant: :fuss_it_out, type: nil} = rec.(nil, nil, 90)
  end

  test "says why" do
    rec = Approaches.recommend(%{age_days: 90, habits: habits(8, 10)})
    assert Enum.any?(rec.reasons, &(&1 =~ "right after a feed"))
  end
end
