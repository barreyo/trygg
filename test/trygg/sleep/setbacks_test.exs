defmodule Trygg.Sleep.SetbacksTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Sleep.Setbacks

  describe "shift_plan/1" do
    test "moves bedtime 15 minutes a day to the target" do
      plan = Setbacks.shift_plan(%{from_bed: 20 * 60 + 30, to_bed: 19 * 60 + 30})

      assert Enum.map(plan, & &1.bed) == [20 * 60 + 15, 20 * 60, 19 * 60 + 45, 19 * 60 + 30]
      assert Enum.map(plan, & &1.day) == [1, 2, 3, 4]
      assert Enum.all?(plan, &is_nil(&1.wake))
    end

    test "moves the wake time along with it" do
      plan =
        Setbacks.shift_plan(%{
          from_bed: 21 * 60,
          to_bed: 20 * 60,
          from_wake: 8 * 60,
          to_wake: 7 * 60
        })

      assert length(plan) == 4
      assert List.last(plan) == %{day: 4, bed: 20 * 60, wake: 7 * 60}
      assert hd(plan).wake == 7 * 60 + 45
    end

    test "a bedtime after midnight counts as the small hours of the night" do
      plan = Setbacks.shift_plan(%{from_bed: 60, to_bed: 22 * 60 + 30})

      # 01:00 is 1500 minutes; 22:30 is 1350: ten steps.
      assert length(plan) == 10
      assert hd(plan).bed == 45
      assert List.last(plan).bed == 22 * 60 + 30
    end

    test "can move later" do
      plan = Setbacks.shift_plan(%{from_bed: 18 * 60, to_bed: 19 * 60})
      assert Enum.map(plan, & &1.bed) == [18 * 60 + 15, 18 * 60 + 30, 18 * 60 + 45, 19 * 60]
    end

    test "is empty when there's nowhere to go, and capped when it's far" do
      assert Setbacks.shift_plan(%{from_bed: 19 * 60, to_bed: 19 * 60}) == []
      assert length(Setbacks.shift_plan(%{from_bed: 6 * 60, to_bed: 23 * 60})) == 60
    end
  end

  describe "dst_plan/3" do
    test "spring: four evenings 15 minutes earlier, ending on the usual time on the new clock" do
      plan = Setbacks.dst_plan(:forward, ~D[2027-03-14], %{bed: 19 * 60, wake: 6 * 60})

      assert Enum.map(plan.rows, & &1.date) ==
               [~D[2027-03-10], ~D[2027-03-11], ~D[2027-03-12], ~D[2027-03-13]]

      assert Enum.map(plan.rows, & &1.bed) == [18 * 60 + 45, 18 * 60 + 30, 18 * 60 + 15, 18 * 60]
      assert Enum.map(plan.rows, & &1.wake) == [5 * 60 + 45, 5 * 60 + 30, 5 * 60 + 15, 6 * 60]
      assert List.last(plan.rows).new_clock?
      refute hd(plan.rows).new_clock?
      assert length(plan.tips) > 0
    end

    test "autumn: nothing to move, it's about light" do
      plan = Setbacks.dst_plan(:back, ~D[2026-10-25], %{bed: 19 * 60, wake: 6 * 60})
      assert plan.rows == []
      assert Enum.any?(plan.tips, &(&1 =~ "bright light"))
    end
  end

  describe "next_dst_change/2" do
    test "finds the clocks going back in autumn" do
      child = %Child{timezone: "Europe/Stockholm"}

      assert %{date: ~D[2026-10-25], direction: :back} =
               Setbacks.next_dst_change(child, ~D[2026-10-11])
    end

    test "finds the clocks going forward in spring" do
      child = %Child{timezone: "Europe/Stockholm"}

      assert %{date: ~D[2027-03-28], direction: :forward} =
               Setbacks.next_dst_change(child, ~D[2027-03-01])
    end

    test "is nil when nothing changes soon, or the zone has no clock change" do
      assert Setbacks.next_dst_change(%Child{timezone: "Europe/Stockholm"}, ~D[2026-12-01]) == nil
      assert Setbacks.next_dst_change(%Child{timezone: "Etc/UTC"}, ~D[2026-10-11]) == nil
    end
  end

  describe "travel_plan/1" do
    test "one hour for a short trip: stay on home time" do
      plan = Setbacks.travel_plan(%{hours: 1, direction: :east, days: 4})
      assert plan.keep_home_time?
      assert plan.adjust_days == 0
      assert plan.light == nil
    end

    test "west: light in the late afternoon, home time; a day an hour to adjust" do
      plan = Setbacks.travel_plan(%{hours: 3, direction: :west, days: 10})
      refute plan.keep_home_time?
      assert plan.adjust_days == 3
      assert {lo, hi} = plan.light
      assert lo >= 16 * 60 and hi <= 20 * 60
    end

    test "east: light early in the morning, home time" do
      plan = Setbacks.travel_plan(%{hours: 6, direction: :east, days: 10})
      assert {lo, hi} = plan.light
      assert lo >= 5 * 60 and hi <= 8 * 60
    end

    test "a long stay across one zone still adjusts" do
      refute Setbacks.travel_plan(%{hours: 1, direction: :west, days: 14}).keep_home_time?
    end
  end

  describe "regression_window/1" do
    test "is near the common ages" do
      assert {4, to_go} = Setbacks.regression_window(110)
      assert to_go == round(4 * 30.4375) - 110
      assert {6, _} = Setbacks.regression_window(182)
    end

    test "is nil between them and without an age" do
      assert Setbacks.regression_window(10) == nil
      assert Setbacks.regression_window(nil) == nil
    end
  end

  test "every playbook has a title, summary and points, and can be looked up" do
    for book <- Setbacks.playbooks() do
      assert book.title != "" and book.summary != "" and book.points != []
      assert Setbacks.playbook(book.id) == book
    end

    assert Setbacks.playbook(:nope) == nil
  end

  test "the medical notes are there" do
    assert Enum.map(Setbacks.medical(), & &1.id) ==
             [:reflux, :allergy, :apnea, :restless_legs, :prematurity]
  end
end
