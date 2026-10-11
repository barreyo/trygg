defmodule Trygg.Sleep.SchedulesTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Sleep.{BedtimePlan, Schedules}

  @child %Child{timezone: "Etc/UTC"}
  @date ~D[2026-10-10]

  defp at(hour, minute \\ 0), do: DateTime.new!(@date, Time.new!(hour, minute, 0), "Etc/UTC")

  describe "for_age/1" do
    test "nothing before 13 weeks" do
      assert Schedules.for_age(90) == nil
      assert Schedules.for_age(nil) == nil
    end

    test "the table for each stage by corrected age" do
      assert %{id: :three_four_months} = Schedules.for_age(91)
      assert %{id: :three_four_months} = Schedules.for_age(151)
      assert %{id: :five_to_seven_months} = Schedules.for_age(152)
      assert %{id: :seven_to_fourteen_months} = Schedules.for_age(213)
      assert %{id: :one_nap} = Schedules.for_age(500)
    end

    test "every table has a nap length and window for each nap" do
      for table <- Schedules.tables() do
        assert length(table.windows) == length(table.nap_minutes)
        assert elem(table.bedtime, 0) < elem(table.bedtime, 1)
      end
    end
  end

  describe "plan_day/3" do
    test "naps follow the wake windows and bedtime follows the last nap" do
      table = Schedules.for_age(100)
      plan = Schedules.plan_day(@child, table, at(7))

      assert [%{ordinal: 1} = nap1, %{ordinal: 2}, %{ordinal: 3}, %{ordinal: 4}, %{kind: :bed}] =
               plan.items

      assert nap1.start == at(8, 15)
      assert nap1.end == at(9, 15)
      assert plan.bedtime == List.last(plan.items).start
    end

    test "bedtime is the last nap's end plus the middle of the guide's gap" do
      table = Schedules.for_age(180)
      plan = Schedules.plan_day(@child, table, at(6, 30))

      last = plan.items |> Enum.filter(&(&1.kind == :nap)) |> List.last()
      {lo, hi} = table.bed_gap
      expected = DateTime.add(last.end, div(lo + hi, 2) * 60, :second)

      # Held only if outside the window; here it isn't.
      assert plan.bedtime == expected
      assert plan.notes == []
    end

    test "a day running long is held at the end of the bedtime window" do
      table = Schedules.for_age(100)
      plan = Schedules.plan_day(@child, table, at(9, 30))

      assert plan.bedtime == at(20)
      assert :late_naps in plan.notes
    end

    test "a very early finish gets an early bedtime, not before 18:00" do
      table = Schedules.for_age(100)
      plan = Schedules.plan_day(@child, table, at(4))

      assert plan.bedtime == at(18)
      assert :early_bedtime in plan.notes
    end
  end

  describe "BedtimePlan.build/2" do
    @table Schedules.for_age(100)

    test "inside the window: keep it, and the last nap ends 100-120 minutes before" do
      plan = BedtimePlan.build(@table, 19 * 60 + 40)

      assert plan.status == :within
      assert plan.tonight == 19 * 60 + 40
      assert plan.steps == []
      assert plan.last_nap_by == {19 * 60 + 40 - 120, 19 * 60 + 40 - 100}
    end

    test "later than the window: shift 15 minutes earlier each evening until it's reached" do
      plan = BedtimePlan.build(@table, 20 * 60 + 40)

      assert plan.status == :late
      assert plan.tonight == 20 * 60 + 25
      assert Enum.map(plan.steps, & &1.minutes) == [20 * 60 + 25, 20 * 60 + 10, 20 * 60]
      assert Enum.map(plan.steps, & &1.evening) == [1, 2, 3]
    end

    test "a bedtime just over the window lands on its edge in one step" do
      plan = BedtimePlan.build(@table, 20 * 60 + 5)
      assert Enum.map(plan.steps, & &1.minutes) == [20 * 60]
      assert plan.tonight == 20 * 60
    end

    test "earlier than the window is left alone" do
      plan = BedtimePlan.build(@table, 18 * 60 + 30)
      assert plan.status == :early
      assert plan.tonight == 18 * 60 + 30
      assert plan.steps == []
    end

    test "no history gives no plan" do
      plan = BedtimePlan.build(@table, nil)
      assert %{status: :unknown, tonight: nil, steps: [], last_nap_by: nil} = plan
    end

    test "clock/1 formats minutes since midnight" do
      assert BedtimePlan.clock(19 * 60 + 5) == "19:05"
      assert BedtimePlan.clock(0) == "00:00"
    end
  end
end
