defmodule Trygg.Sleep.DaySchedulesTest do
  use Trygg.DataCase, async: true

  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.Sleep.{DaySchedule, DaySchedules, Phase, Schedules}

  defp child_of_age(scope, days),
    do: child_fixture(scope, %{birth_date: Date.add(Date.utc_today(), -days)})

  defp effective(child, schedule \\ nil, inputs \\ %{}),
    do: DaySchedules.effective(child, Phase.for_child(child), schedule, inputs)

  setup do
    scope = user_scope_fixture()
    %{scope: scope}
  end

  describe "effective/4 for a newborn" do
    test "is a soft rhythm with no nap times", %{scope: scope} do
      eff = effective(child_fixture(scope))

      assert eff.mode == :newborn
      assert eff.day == nil
      assert eff.slots == []
      assert eff.wake == %{minutes: 7 * 60, source: :guide}
      assert eff.bedtime == nil
      assert {lo, hi} = eff.newborn.wake_window
      assert lo < hi
    end

    test "the log fills the anchors and a pin wins over it", %{scope: scope} do
      child = child_fixture(scope)
      inputs = %{observed_wake: 6 * 60 + 30, observed_bed: 21 * 60}

      eff = effective(child, nil, inputs)
      assert eff.wake == %{minutes: 390, source: :observed}
      assert eff.bedtime == %{minutes: 1260, source: :observed}

      eff = effective(child, %DaySchedule{wake_minutes: 480}, inputs)
      assert eff.wake == %{minutes: 480, source: :pinned}
      assert eff.customized?
    end

    test "nothing without a birth date", %{scope: scope} do
      assert DaySchedules.effective(child_fixture(scope), nil, nil) == nil
    end
  end

  describe "effective/4 from 13 weeks" do
    setup %{scope: scope} do
      %{child: child_of_age(scope, 100)}
    end

    test "with nothing set it is the guide's day", %{child: child} do
      table = Schedules.for_age(100)
      eff = effective(child)

      assert eff.mode == :guide
      refute eff.customized?
      assert Enum.map(eff.slots, & &1.window.minutes) == table.windows
      assert Enum.all?(eff.slots, &(&1.window.source == :guide))
      assert eff.nap_count == %{value: 4, source: :guide, guide: 4}
      assert eff.bedtime.source == :guide
      assert length(eff.day.items) == 5
    end

    test "a pinned wake window moves the nap and shows as yours", %{child: child} do
      guide = effective(child)
      eff = effective(child, %DaySchedule{wake_windows: [nil, 120]})

      assert [
               %{window: %{source: :guide}},
               %{window: %{minutes: 120, source: :pinned, guide: 90}} | _
             ] =
               eff.slots

      [_, nap1_guide | _] = guide.day.items
      [_, nap1_pinned | _] = eff.day.items
      assert DateTime.diff(nap1_pinned.start, nap1_guide.start, :minute) == 30
    end

    test "a different nap count resizes the day", %{child: child} do
      eff = effective(child, %DaySchedule{nap_count: 3})

      assert eff.nap_count == %{value: 3, source: :pinned, guide: 4}
      assert length(eff.slots) == 3
      assert length(eff.day.items) == 4
      assert eff.table.naps == "3"
    end

    test "more naps than the guide has reuse its last slot", %{child: child} do
      eff = effective(child, %DaySchedule{nap_count: 5})
      assert [_, _, _, _, %{window: %{minutes: 90, source: :guide}}] = eff.slots
    end

    test "a pinned bedtime is the day's bedtime, and says when the last nap is too close",
         %{child: child} do
      eff = effective(child, %DaySchedule{bedtime_minutes: 17 * 60})

      assert eff.bedtime == %{minutes: 1020, source: :pinned}
      assert Schedules.local_minutes(child, eff.day.bedtime) == 1020
      assert :short_gap in eff.day.notes
    end

    test "today's wake-up anchors the day, else the target does", %{child: child} do
      wake = DateTime.add(DateTime.utc_now(), -3600, :second)

      assert %{anchor: :today, wake_at: ^wake} = effective(child, nil, %{today_wake: wake})
      assert %{anchor: :target} = effective(child, %DaySchedule{wake_minutes: 6 * 60})
    end

    test "says when the guide has moved on since the choices were saved", %{child: child} do
      id = DaySchedules.guide_id(Phase.for_child(child))

      refute effective(child, %DaySchedule{nap_count: 3, guide_id: id}).stale?
      assert effective(child, %DaySchedule{nap_count: 3, guide_id: "newborn"}).stale?
      # A row kept only for its dismissed suggestions has no choices to review.
      refute effective(child, %DaySchedule{guide_id: "newborn"}).stale?
    end
  end

  describe "save/3 and get/2" do
    setup %{scope: scope} do
      %{child: child_of_age(scope, 100)}
    end

    test "stores only what was set and reads it back", %{scope: scope, child: child} do
      params = %{
        "wake" => "06:45",
        "bedtime" => "",
        "naps" => "3",
        "windows" => %{"0" => "", "1" => "100"}
      }

      assert {:ok, %DaySchedule{} = saved} =
               DaySchedules.save(scope, child, DaySchedules.parse_params(params))

      assert saved.wake_minutes == 405
      assert saved.bedtime_minutes == nil
      assert saved.nap_count == 3
      assert saved.wake_windows == [nil, 100]
      assert saved.guide_id == "three_four_months"
      assert DaySchedules.get(scope, child).id == saved.id
    end

    test "saving again replaces the choices", %{scope: scope, child: child} do
      {:ok, first} = DaySchedules.save(scope, child, %{wake_minutes: 400})
      {:ok, second} = DaySchedules.save(scope, child, %{bedtime_minutes: 1140})

      assert first.id == second.id
      assert second.wake_minutes == nil
      assert second.bedtime_minutes == 1140
    end

    test "slots past the nap count are dropped", %{scope: scope, child: child} do
      {:ok, saved} =
        DaySchedules.save(scope, child, %{
          nap_count: 2,
          wake_windows: [80, 90, 100],
          nap_lengths: []
        })

      assert saved.wake_windows == [80, 90]
    end

    test "saving only blanks puts them back on the guide", %{scope: scope, child: child} do
      {:ok, _} = DaySchedules.save(scope, child, %{wake_minutes: 400})

      assert {:ok, nil} =
               DaySchedules.save(scope, child, DaySchedules.parse_params(%{"wake" => ""}))

      assert DaySchedules.get(scope, child) == nil
    end

    test "rejects values outside sensible ranges", %{scope: scope, child: child} do
      assert {:error, changeset} = DaySchedules.save(scope, child, %{wake_windows: [5]})
      assert %{wake_windows: [_]} = errors_on(changeset)

      assert {:error, changeset} = DaySchedules.save(scope, child, %{bedtime_minutes: 10 * 60})
      assert %{bedtime_minutes: [_]} = errors_on(changeset)

      assert {:error, changeset} = DaySchedules.save(scope, child, %{nap_count: 9})
      assert %{nap_count: [_]} = errors_on(changeset)
    end

    test "acknowledge/2 re-stamps the guide", %{scope: scope, child: child} do
      {:ok, saved} = DaySchedules.save(scope, child, %{wake_minutes: 400})
      Repo.update_all(DaySchedule, set: [guide_id: "newborn"])

      assert {:ok, %{guide_id: "three_four_months"}} = DaySchedules.acknowledge(scope, child)
      assert DaySchedules.get(scope, child).id == saved.id
    end

    test "viewers can read but not write" do
      %{owner_scope: owner, child: child, member_scope: viewer} = shared_child_fixture(:viewer)
      {:ok, _} = DaySchedules.save(owner, child, %{wake_minutes: 400})

      assert %DaySchedule{wake_minutes: 400} = DaySchedules.get(viewer, child)

      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        DaySchedules.save(viewer, child, %{wake_minutes: 300})
      end

      assert_raise Trygg.Families.NotAuthorizedError, fn -> DaySchedules.clear(viewer, child) end
    end

    test "strangers can't read it", %{scope: scope, child: child} do
      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        DaySchedules.get(user_scope_fixture(), child)
      end

      _ = scope
    end
  end

  describe "accept/3 and dismiss/3" do
    setup %{scope: scope} do
      %{child: child_of_age(scope, 100)}
    end

    test "accepting lays the change over what's set and notes it", %{scope: scope, child: child} do
      {:ok, _} = DaySchedules.save(scope, child, %{wake_minutes: 400, wake_windows: [80]})

      suggestion = %{id: :nap_count, title: "Plan 3 naps a day", change: %{nap_count: 3}}
      assert {:ok, saved} = DaySchedules.accept(scope, child, suggestion)

      assert %{wake_minutes: 400, wake_windows: [80], nap_count: 3} = saved
      assert [%{"id" => "nap_count", "title" => "Plan 3 naps a day", "on" => on}] = saved.history
      assert on == Date.to_iso8601(Trygg.Families.Child.local_today(child))
    end

    test "accepting works from nothing, and a bad change is refused", %{
      scope: scope,
      child: child
    } do
      assert {:ok, %{nap_count: 2}} =
               DaySchedules.accept(scope, child, %{
                 id: :nap_count,
                 title: "t",
                 change: %{nap_count: 2}
               })

      assert {:error, _} =
               DaySchedules.accept(scope, child, %{
                 id: :nap_count,
                 title: "t",
                 change: %{nap_count: 9}
               })
    end

    test "history keeps the latest ten", %{scope: scope, child: child} do
      for n <- 1..12 do
        {:ok, _} =
          DaySchedules.accept(scope, child, %{
            id: :bedtime_earlier,
            title: "t#{n}",
            change: %{bedtime_minutes: 1100 + n}
          })
      end

      assert %{history: history} = DaySchedules.get(scope, child)
      assert length(history) == 10
      assert List.last(history)["title"] == "t12"
    end

    test "dismissing remembers the key without choosing anything", %{scope: scope, child: child} do
      assert {:ok, saved} = DaySchedules.dismiss(scope, child, "nap_count:3")
      today = Date.to_iso8601(Trygg.Families.Child.local_today(child))

      assert saved.dismissed == %{"nap_count:3" => today}
      assert DaySchedule.empty?(saved)

      effective = DaySchedules.effective(child, Phase.for_child(child), saved)
      refute effective.customized?
      refute effective.stale?
    end

    test "saving the form keeps dismissals and history; going back to the guide clears them", %{
      scope: scope,
      child: child
    } do
      {:ok, _} = DaySchedules.dismiss(scope, child, "nap_count:3")

      {:ok, _} =
        DaySchedules.accept(scope, child, %{id: :nap_count, title: "t", change: %{nap_count: 3}})

      {:ok, saved} = DaySchedules.save(scope, child, %{wake_minutes: 400})
      assert saved.dismissed != %{}
      assert length(saved.history) == 1

      # Blanking every choice keeps the row for what it remembers.
      assert {:ok, %DaySchedule{nap_count: nil}} = DaySchedules.save(scope, child, %{})

      {:ok, nil} = DaySchedules.clear(scope, child)
      assert DaySchedules.get(scope, child) == nil
    end

    test "old dismissals are dropped when a new one is added", %{scope: scope, child: child} do
      {:ok, _} = DaySchedules.dismiss(scope, child, "old:1")
      Repo.update_all(DaySchedule, set: [dismissed: %{"old:1" => "2026-01-01"}])

      {:ok, saved} = DaySchedules.dismiss(scope, child, "new:2")
      assert Map.keys(saved.dismissed) == ["new:2"]
    end

    test "viewers can't" do
      %{child: child, member_scope: viewer} = shared_child_fixture(:viewer)

      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        DaySchedules.dismiss(viewer, child, "k")
      end

      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        DaySchedules.accept(viewer, child, %{id: :nap_count, title: "t", change: %{nap_count: 2}})
      end
    end
  end

  describe "parse_params/1" do
    test "blanks and junk follow the guide; slots keep their positions" do
      parsed =
        DaySchedules.parse_params(%{
          "wake" => "nope",
          "bedtime" => "19:15",
          "naps" => "",
          "windows" => %{"2" => "95", "0" => "", "1" => "x"},
          "lengths" => nil
        })

      assert parsed == %{
               wake_minutes: nil,
               bedtime_minutes: 1155,
               nap_count: nil,
               wake_windows: [nil, nil, 95],
               nap_lengths: []
             }
    end
  end
end
