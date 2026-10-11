defmodule Trygg.Sleep.SwapTest do
  use ExUnit.Case, async: true

  alias Trygg.Sleep.Swap

  test "opens at two months corrected" do
    assert Swap.min_age_days() == 61
  end

  test "the seven variants" do
    assert Enum.map(Swap.variants(), & &1.id) ==
             [:jiggle, :pat, :pull_out, :anything_but, :chair, :fuss_it_out, :double_take]

    assert Swap.variant_ids() ==
             ~w(jiggle pat pull_out anything_but chair fuss_it_out double_take)
  end

  test "variant/1 takes an atom or a string" do
    assert Swap.variant(:chair).name == "The chair fade"
    assert Swap.variant("chair").id == :chair
    assert Swap.variant("nope") == nil
    assert Swap.variant(nil) == nil
  end

  test "most run a week, the chair ten nights and the fuss-it-out trial five" do
    assert Swap.nights(:jiggle) == 7
    assert Swap.nights(:chair) == 10
    assert Swap.nights("fuss_it_out") == 5
    assert Swap.nights("unknown") == 7
  end

  describe "tonight/3" do
    test "jiggling or patting comes down five minutes a night from where it started" do
      opts = %{"start_minutes" => 35}

      assert %{target_minutes: 35} = Swap.tonight(:jiggle, 1, opts)
      assert %{target_minutes: 30} = Swap.tonight(:jiggle, 2, opts)
      assert %{target_minutes: 5} = Swap.tonight(:pat, 7, opts)
      assert %{target_minutes: 0, headline: headline} = Swap.tonight(:pat, 8, opts)
      assert headline =~ "put them down awake"
      assert %{target_minutes: 0} = Swap.tonight(:jiggle, 20, opts)
    end

    test "starts from 30 minutes when nothing was noted" do
      assert %{target_minutes: 30} = Swap.tonight(:jiggle, 1)
      assert %{target_minutes: 30} = Swap.tonight(:jiggle, 1, %{"start_minutes" => nil})
    end

    test "the chair has three stages and moves two feet a night" do
      assert Swap.tonight(:chair, 1).headline =~ "touching"
      assert Swap.tonight(:chair, 2).headline =~ "touching"
      assert Swap.tonight(:chair, 3).headline =~ "less"
      assert Swap.tonight(:chair, 5).headline =~ "2 feet"
      assert Swap.tonight(:chair, 7).headline =~ "6 feet"
      assert Swap.tonight(:chair, 9).headline =~ "10 feet"
      assert Swap.tonight(:chair, 9).headline =~ "door"
    end

    test "the others say the same thing every night" do
      for id <- [:pull_out, :anything_but, :double_take] do
        assert Swap.tonight(id, 1) == Swap.tonight(id, 5)
      end

      assert %{target_minutes: 20} = Swap.tonight(:fuss_it_out, 1)
    end

    test "an unknown variant is an error" do
      assert_raise ArgumentError, fn -> Swap.tonight(:nope, 1) end
    end
  end

  describe "assess/2" do
    defp night(number, minutes), do: %{number: number, bedtime_to_sleep_seconds: minutes * 60}

    test "too soon before three nights" do
      assert {:early, _} = Swap.assess([night(1, 40), night(2, 30)], 7)
    end

    test "improving, steady and stalled" do
      assert {:improving, _} = Swap.assess([night(1, 40), night(2, 30), night(3, 20)], 7)
      assert {:steady, _} = Swap.assess([night(1, 40), night(2, 38), night(3, 41)], 7)

      nights = for n <- 1..7, do: night(n, 40)
      assert {:stalled, text} = Swap.assess(nights, 7)
      assert text =~ "another variant"
    end
  end

  test "there are signs, reasons and things to check" do
    assert length(Swap.signs_of_progress()) == 4
    assert length(Swap.reasons_it_stalls()) == 4
    assert length(Swap.still_waking()) == 5
    assert length(Swap.preflight()) == 5
    assert Enum.all?(Swap.preflight_ids(), &String.starts_with?(&1, "w-"))
  end
end
