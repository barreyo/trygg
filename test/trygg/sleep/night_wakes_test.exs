defmodule Trygg.Sleep.NightWakesTest do
  use Trygg.DataCase, async: true

  import Trygg.FamiliesFixtures

  alias Trygg.Families
  alias Trygg.Sleep.{NightWake, NightWakes}

  setup do
    %{owner_scope: owner, child: child, member_scope: member} = shared_child_fixture(:caregiver)
    Families.subscribe(child.id)
    %{owner: owner, child: child, member: member}
  end

  describe "start/3" do
    test "starts a waking at the first step and broadcasts it", %{owner: owner, child: child} do
      assert {:ok, %NightWake{method: :sit_back, step: 0, ended_at: nil} = wake} =
               NightWakes.start(owner, child, :sit_back)

      assert wake.started_by_id == owner.user.id
      assert wake.step_started_at == wake.started_at
      assert_receive {:night_wake, :started, %{id: id}} when id == wake.id
    end

    test "a second start returns the one in progress", %{
      owner: owner,
      child: child,
      member: member
    } do
      {:ok, first} = NightWakes.start(owner, child, :sit_back)
      assert {:ok, second} = NightWakes.start(member, child, :sit_back)

      assert second.id == first.id
      assert Repo.aggregate(NightWake, :count) == 1
    end

    test "only caregivers can start one" do
      %{child: child, member_scope: viewer} = shared_child_fixture(:viewer)

      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        NightWakes.start(viewer, child, :cries)
      end
    end

    test "only known methods", %{owner: owner, child: child} do
      assert_raise FunctionClauseError, fn -> apply(NightWakes, :start, [owner, child, :nope]) end
    end
  end

  describe "active/2" do
    test "is the waking in progress, then nothing once it ends", %{owner: owner, child: child} do
      assert NightWakes.active(owner, child) == nil
      {:ok, wake} = NightWakes.start(owner, child, :sit_back)
      assert %{id: id, started_by: %{}} = NightWakes.active(owner, child)
      assert id == wake.id

      {:ok, _} = NightWakes.finish(owner, wake, :settled)
      assert NightWakes.active(owner, child) == nil
    end

    test "a viewer can read it", %{owner: owner, child: child} do
      {:ok, wake} = NightWakes.start(owner, child, :sit_back)
      viewer = user_viewer(child)
      assert %{id: id} = NightWakes.active(viewer, child)
      assert id == wake.id
    end
  end

  describe "advance/3 and restart/3" do
    test "moves to the next step, resets the step clock and broadcasts", %{
      owner: owner,
      child: child
    } do
      {:ok, wake} = NightWakes.start(owner, child, :sit_back)
      flush()

      assert {:ok, moved} = NightWakes.advance(owner, wake, 0)
      assert moved.step == 1
      assert DateTime.compare(moved.step_started_at, wake.step_started_at) != :lt
      assert_receive {:night_wake, :advanced, %{step: 1}}
    end

    test "two people tapping next at once move it on once", %{
      owner: owner,
      child: child,
      member: member
    } do
      {:ok, wake} = NightWakes.start(owner, child, :sit_back)
      flush()

      assert {:ok, %{step: 1}} = NightWakes.advance(owner, wake, 0)
      assert {:ok, %{step: 1}} = NightWakes.advance(member, wake, 0)
      assert_receive {:night_wake, :advanced, _}
      refute_receive {:night_wake, :advanced, _}, 50
    end

    test "can't go past the last step", %{owner: owner, child: child} do
      {:ok, wake} = NightWakes.start(owner, child, :cries)

      moved =
        Enum.reduce(0..3, wake, fn step, acc ->
          {:ok, next} = NightWakes.advance(owner, acc, step)
          next
        end)

      assert moved.step == 4
      assert {:error, :last_step} = NightWakes.advance(owner, moved, 4)
    end

    test "restart goes back to the first step", %{owner: owner, child: child} do
      {:ok, wake} = NightWakes.start(owner, child, :sit_back)
      {:ok, wake} = NightWakes.advance(owner, wake, 0)
      {:ok, wake} = NightWakes.advance(owner, wake, 1)

      assert {:ok, %{step: 0}} = NightWakes.restart(owner, wake, 2)
    end

    test "a stale change after it ended does nothing", %{owner: owner, child: child} do
      {:ok, wake} = NightWakes.start(owner, child, :sit_back)
      {:ok, ended} = NightWakes.finish(owner, wake, :settled)

      assert {:ok, %{step: 0, ended_at: %DateTime{}}} = NightWakes.advance(owner, wake, 0)
      assert ended.outcome == :settled
    end
  end

  describe "finish/3" do
    test "records the outcome and the step it was on, and broadcasts", %{
      owner: owner,
      child: child
    } do
      {:ok, wake} = NightWakes.start(owner, child, :sit_back)
      {:ok, wake} = NightWakes.advance(owner, wake, 0)
      {:ok, wake} = NightWakes.advance(owner, wake, 1)
      flush()

      assert {:ok, ended} = NightWakes.finish(owner, wake, :settled)
      assert ended.outcome == :settled
      assert ended.settled_step == 2
      assert %DateTime{} = ended.ended_at
      assert_receive {:night_wake, :finished, %{outcome: :settled}}
    end

    test "finishing twice keeps the first outcome and broadcasts once", %{
      owner: owner,
      child: child
    } do
      {:ok, wake} = NightWakes.start(owner, child, :sit_back)
      {:ok, _} = NightWakes.finish(owner, wake, :fed)
      flush()

      assert {:ok, %{outcome: :fed}} = NightWakes.finish(owner, wake, :settled)
      refute_receive {:night_wake, :finished, _}, 50
    end

    test "a new waking can start after one ends", %{owner: owner, child: child} do
      {:ok, wake} = NightWakes.start(owner, child, :sit_back)
      {:ok, _} = NightWakes.finish(owner, wake, :stopped)
      assert {:ok, second} = NightWakes.start(owner, child, :sit_back)
      assert second.id != wake.id
    end

    test "viewers can't change a waking", %{owner: owner, child: child} do
      {:ok, wake} = NightWakes.start(owner, child, :sit_back)
      viewer = user_viewer(child)

      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        NightWakes.finish(viewer, wake, :settled)
      end

      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        NightWakes.advance(viewer, wake, 0)
      end
    end
  end

  describe "recent/3 and summarize/1" do
    test "lists wakings from the window, newest first, and summarises the finished ones", %{
      owner: owner,
      child: child
    } do
      {:ok, a} = NightWakes.start(owner, child, :sit_back)
      {:ok, a} = NightWakes.advance(owner, a, 0)
      {:ok, a} = NightWakes.advance(owner, a, 1)
      {:ok, _} = NightWakes.finish(owner, a, :settled)

      {:ok, b} = NightWakes.start(owner, child, :sit_back)
      {:ok, _} = NightWakes.finish(owner, b, :settled)

      {:ok, c} = NightWakes.start(owner, child, :sit_back)

      {:ok, c} =
        Enum.reduce(0..5, {:ok, c}, fn step, {:ok, w} -> NightWakes.advance(owner, w, step) end)

      {:ok, _} = NightWakes.finish(owner, c, :fed)

      {:ok, _active} = NightWakes.start(owner, child, :sit_back)

      wakes = NightWakes.recent(owner, child)
      assert length(wakes) == 4
      assert hd(wakes).ended_at == nil

      assert %{count: 3, settled: 2, fed: 1, stopped: 0, settled_at: %{2 => 1, 0 => 1}} =
               NightWakes.summarize(wakes)
    end

    test "old wakings fall outside the window", %{owner: owner, child: child} do
      {:ok, wake} = NightWakes.start(owner, child, :sit_back)
      {:ok, _} = NightWakes.finish(owner, wake, :settled)

      old = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second) |> DateTime.truncate(:second)
      Repo.update_all(NightWake, set: [started_at: old])

      assert NightWakes.recent(owner, child, 7) == []
      assert length(NightWakes.recent(owner, child, 14)) == 1
    end

    test "check-in wakings (no step) count as settled but not at a step", %{
      owner: owner,
      child: child
    } do
      {:ok, wake} = NightWakes.start(owner, child, :abcs)
      {:ok, _} = NightWakes.asleep(owner, wake, 1)

      assert %{count: 1, settled: 1, settled_at: settled_at} =
               NightWakes.summarize(NightWakes.recent(owner, child))

      assert settled_at == %{}
    end

    test "summarize/1 of nothing", _ctx do
      assert %{count: 0, settled: 0, fed: 0, stopped: 0, settled_at: %{}} ==
               NightWakes.summarize([])
    end
  end

  describe "seconds_left/2" do
    test "counts down the timed steps and is nil for untimed ones", %{owner: owner, child: child} do
      {:ok, wake} = NightWakes.start(owner, child, :sit_back)

      assert NightWakes.seconds_left(wake, wake.step_started_at) == 300

      assert NightWakes.seconds_left(wake, DateTime.add(wake.step_started_at, 100, :second)) ==
               200

      assert NightWakes.seconds_left(wake, DateTime.add(wake.step_started_at, 400, :second)) ==
               -100

      assert NightWakes.seconds_left(%{wake | step: 6}, wake.step_started_at) == nil

      {:ok, _} = NightWakes.finish(owner, wake, :stopped)
      {:ok, cries} = NightWakes.start(owner, child, :cries)
      assert NightWakes.seconds_left(cries, cries.step_started_at) == nil
    end
  end

  defp flush do
    receive do
      {:night_wake, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp user_viewer(child) do
    user = Trygg.AccountsFixtures.user_fixture()
    membership_fixture(child, user, :viewer)
    Trygg.AccountsFixtures.user_scope_fixture(user)
  end

  describe "ABCs check-ins" do
    alias Trygg.Sleep.Checkins

    test "a waking starts with the crying already begun", %{owner: owner, child: child} do
      assert {:ok, wake} = NightWakes.start(owner, child, :abcs)

      assert wake.method == :abcs
      assert wake.kind == :waking
      assert [%{"kind" => "cry"}] = wake.events
      assert %{phase: :crying, pop_ins: 0} = Checkins.state(wake.events, DateTime.utc_now())
    end

    test "the bedtime put-down starts with no events", %{owner: owner, child: child} do
      assert {:ok, wake} = NightWakes.start(owner, child, :abcs, kind: :bedtime)
      assert wake.kind == :bedtime
      assert wake.events == []
    end

    test "records pop-ins, calming and crying again, and broadcasts", %{
      owner: owner,
      child: child
    } do
      {:ok, wake} = NightWakes.start(owner, child, :abcs)
      flush()

      {:ok, wake} = NightWakes.record(owner, wake, "pop_in", 1)
      assert Enum.map(wake.events, & &1["kind"]) == ["cry", "pop_in"]
      assert_receive {:night_wake, :advanced, %{events: [_, _]}}

      {:ok, wake} = NightWakes.record(owner, wake, "calm", 2)
      {:ok, wake} = NightWakes.record(owner, wake, "cry", 3)
      assert Enum.map(wake.events, & &1["kind"]) == ["cry", "pop_in", "calm", "cry"]
    end

    test "a double tap records one event", %{owner: owner, child: child, member: member} do
      {:ok, wake} = NightWakes.start(owner, child, :abcs)
      flush()

      {:ok, _} = NightWakes.record(owner, wake, "pop_in", 1)
      {:ok, again} = NightWakes.record(member, wake, "pop_in", 1)

      assert length(again.events) == 2
      assert_receive {:night_wake, :advanced, _}
      refute_receive {:night_wake, :advanced, _}, 50
    end

    test "recording needs a known kind, and a caregiver", %{owner: owner, child: child} do
      {:ok, wake} = NightWakes.start(owner, child, :abcs)

      assert_raise FunctionClauseError, fn ->
        apply(NightWakes, :record, [owner, wake, "shout", 1])
      end

      viewer = user_viewer(child)

      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        NightWakes.record(viewer, wake, "pop_in", 1)
      end

      assert_raise Trygg.Families.NotAuthorizedError, fn -> NightWakes.asleep(viewer, wake, 1) end
    end

    test "falling asleep ends it as settled with the crying time", %{owner: owner, child: child} do
      {:ok, wake} = NightWakes.start(owner, child, :abcs)
      # Make the crying a known length: it began 12 minutes ago.
      back = DateTime.add(DateTime.utc_now(), -12 * 60, :second)

      Repo.update_all(NightWake,
        set: [events: [Checkins.event("cry", back)], started_at: DateTime.truncate(back, :second)]
      )

      wake = Repo.get!(NightWake, wake.id)
      flush()

      assert {:ok, ended} = NightWakes.asleep(owner, wake, 1)
      assert ended.outcome == :settled
      assert %DateTime{} = ended.ended_at
      assert ended.cry_seconds in 719..722
      assert List.last(ended.events)["kind"] == "asleep"
      assert_receive {:night_wake, :finished, %{outcome: :settled}}
      assert NightWakes.active(owner, child) == nil
    end

    test "falling asleep twice ends it once", %{owner: owner, child: child, member: member} do
      {:ok, wake} = NightWakes.start(owner, child, :abcs)
      flush()

      {:ok, first} = NightWakes.asleep(owner, wake, 1)
      {:ok, second} = NightWakes.asleep(member, wake, 1)

      assert second.id == first.id
      assert length(second.events) == 2
      assert_receive {:night_wake, :finished, _}
      refute_receive {:night_wake, :finished, _}, 50
    end

    test "stopping without a result still totals the crying", %{owner: owner, child: child} do
      {:ok, wake} = NightWakes.start(owner, child, :abcs)
      back = DateTime.add(DateTime.utc_now(), -5 * 60, :second)
      Repo.update_all(NightWake, set: [events: [Checkins.event("cry", back)]])

      {:ok, ended} = NightWakes.finish(owner, Repo.get!(NightWake, wake.id), :stopped)
      assert ended.outcome == :stopped
      assert ended.cry_seconds in 299..302
    end

    test "a bedtime put-down with no crying falls asleep with zero crying", %{
      owner: owner,
      child: child
    } do
      {:ok, wake} = NightWakes.start(owner, child, :abcs, kind: :bedtime)
      assert {:ok, ended} = NightWakes.asleep(owner, wake, 0)
      assert ended.cry_seconds == 0
      assert ended.outcome == :settled
    end

    test "links the waking to a plan", %{owner: owner, child: child} do
      {:ok, wake} = NightWakes.start(owner, child, :abcs, plan_id: nil)
      assert wake.plan_id == nil
    end
  end
end
