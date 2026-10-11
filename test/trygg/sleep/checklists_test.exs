defmodule Trygg.Sleep.ChecklistsTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Sleep.Checklists

  @child %Child{timezone: "Etc/UTC", sleep_checks: %{}}

  defp night(attrs) do
    Map.merge(
      %{
        bedtime: ~U[2026-10-01 19:30:00Z],
        feeds: 1,
        wakings: 1,
        feed_events: [],
        longest_sleep_seconds: 0
      },
      Map.new(attrs)
    )
  end

  defp ctx(attrs \\ []) do
    %{
      child: @child,
      nights: %{nights: []},
      falling_asleep: %{tracked: 0, weeks: [], this_week: %{mean_level: nil}, trend: nil},
      habits: %{week: %{cued: 0}}
    }
    |> Map.merge(Map.new(attrs))
  end

  defp item(result, id), do: Enum.find(result.success ++ result.troubleshooting, &(&1.id == id))

  test "24 success items and 13 troubleshooting questions" do
    result = Checklists.evaluate(ctx())
    assert result.success_total == 24
    assert length(result.troubleshooting) == 13
    assert result.success_done == 0
  end

  test "ids are unique and match the exposed lists" do
    assert Checklists.success_ids() == Enum.uniq(Checklists.success_ids())
    assert Checklists.troubleshooting_ids() == Enum.uniq(Checklists.troubleshooting_ids())
    result = Checklists.evaluate(ctx())
    assert Enum.map(result.success, & &1.id) == Checklists.success_ids()
  end

  describe "ticks by hand" do
    test "manual items follow sleep_checks" do
      child = %{
        @child
        | sleep_checks: %{"environment" => "2026-10-02", "t-feeds" => "2026-10-03"}
      }

      result = Checklists.evaluate(ctx(child: child))

      assert item(result, "environment").checked?
      refute item(result, "environment").auto?
      refute item(result, "routine").checked?
      assert item(result, "t-feeds").checked?
      assert result.success_done == 1
    end

    test "an automatic item ignores a manual tick" do
      child = %{@child | sleep_checks: %{"day-calories" => "2026-10-02"}}
      assert item(Checklists.evaluate(ctx(child: child)), "day-calories").checked? == false
    end
  end

  describe "automatic items" do
    test "day calories: at most one night feed a night over 3+ nights" do
      ok = ctx(nights: %{nights: List.duplicate(night(feeds: 1), 4)})
      assert %{checked?: true} = item(Checklists.evaluate(ok), "day-calories")

      many = ctx(nights: %{nights: List.duplicate(night(feeds: 3), 4)})
      assert %{checked?: false} = item(Checklists.evaluate(many), "day-calories")

      few = ctx(nights: %{nights: List.duplicate(night(feeds: 0), 2)})

      assert %{checked?: false, detail: "needs 3 nights"} =
               item(Checklists.evaluate(few), "day-calories")
    end

    test "consistent bedtime: 4 of the last 5 between 7 and 8 pm" do
      inside = night(bedtime: ~U[2026-10-01 19:30:00Z])
      outside = night(bedtime: ~U[2026-10-01 21:00:00Z])

      assert %{checked?: true} =
               item(
                 Checklists.evaluate(
                   ctx(nights: %{nights: [inside, inside, inside, inside, outside]})
                 ),
                 "bedtime-consistent"
               )

      assert %{checked?: false} =
               item(
                 Checklists.evaluate(
                   ctx(nights: %{nights: [inside, inside, inside, outside, outside]})
                 ),
                 "bedtime-consistent"
               )
    end

    test "not every waking ends in a feed" do
      fed = night(wakings: 1, feeds: 1)
      settled = night(wakings: 2, feeds: 1)

      assert %{checked?: true} =
               item(
                 Checklists.evaluate(ctx(nights: %{nights: [fed, settled]})),
                 "not-every-waking-fed"
               )

      assert %{checked?: false} =
               item(
                 Checklists.evaluate(ctx(nights: %{nights: [fed, fed]})),
                 "not-every-waking-fed"
               )
    end

    test "fewer wakings and fewer night feeds: last 3 nights against the 3 before" do
      better =
        List.duplicate(night(wakings: 1, feeds: 0), 3) ++
          List.duplicate(night(wakings: 3, feeds: 2), 3)

      result = Checklists.evaluate(ctx(nights: %{nights: better}))
      assert item(result, "fewer-wakings").checked?
      assert item(result, "fewer-night-feeds").checked?

      worse = Enum.reverse(better)
      result = Checklists.evaluate(ctx(nights: %{nights: worse}))
      refute item(result, "fewer-wakings").checked?

      assert item(
               Checklists.evaluate(ctx(nights: %{nights: Enum.take(better, 4)})),
               "fewer-wakings"
             ).detail ==
               "needs 6 nights"
    end

    test "falling asleep alone: trending down in help, or mostly at level 7+" do
      trending = %{tracked: 5, weeks: [], this_week: %{mean_level: 5.0}, trend: 0.8}

      assert item(Checklists.evaluate(ctx(falling_asleep: trending)), "falling-asleep-alone").checked?

      high = %{tracked: 5, weeks: [], this_week: %{mean_level: 7.4}, trend: nil}
      assert item(Checklists.evaluate(ctx(falling_asleep: high)), "falling-asleep-alone").checked?

      flat = %{tracked: 5, weeks: [], this_week: %{mean_level: 4.0}, trend: -0.2}
      refute item(Checklists.evaluate(ctx(falling_asleep: flat)), "falling-asleep-alone").checked?

      refute item(Checklists.evaluate(ctx()), "falling-asleep-alone").checked?
    end

    test "seen them put themselves to sleep: any level 8-9 sleep" do
      weeks = [%{independent_share: nil}, %{independent_share: 0.25}]
      fa = %{tracked: 4, weeks: weeks, this_week: %{mean_level: 6.0}, trend: nil}
      assert item(Checklists.evaluate(ctx(falling_asleep: fa)), "seen-self-sleep").checked?
    end

    test "noting cues and watching windows: 3 sleeps with a cue this week" do
      assert item(Checklists.evaluate(ctx(habits: %{week: %{cued: 3}})), "cues-and-windows").checked?

      refute item(Checklists.evaluate(ctx(habits: %{week: %{cued: 2}})), "cues-and-windows").checked?
    end
  end

  test "troubleshooting hints come from the data" do
    fa = %{tracked: 4, weeks: [], this_week: %{mean_level: 6.5}, trend: nil}
    nights = %{nights: List.duplicate(night(feeds: 3), 3)}
    result = Checklists.evaluate(ctx(falling_asleep: fa, nights: nights))

    assert item(result, "t-fall-asleep").detail =~ "6.5 of 9"
    assert item(result, "t-calories").detail =~ "3.0 night feeds"
    assert item(result, "t-feeds").detail == nil
  end
end
