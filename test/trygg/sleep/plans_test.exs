defmodule Trygg.Sleep.PlansTest do
  use Trygg.DataCase, async: true

  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.Families
  alias Trygg.Sleep.{Abcs, Phase, Plan, Plans}

  # A child old enough for the plan, with the go-ahead and every pre-flight item
  # ticked, so a test only has to break what it's about.
  defp ready_child(scope, attrs \\ %{}) do
    child =
      child_fixture(scope, Map.merge(%{birth_date: Date.add(Date.utc_today(), -170)}, attrs))

    {:ok, child} =
      Families.update_sleep_toolkit(scope, child, %{sleep_training_cleared_on: Date.utc_today()})

    checks = Map.new(Abcs.preflight_ids(), &{&1, Date.to_iso8601(Date.utc_today())})
    {:ok, child} = Families.update_sleep_toolkit(scope, child, %{sleep_checks: checks})
    child
  end

  defp phase(child), do: Phase.for_child(child)

  setup do
    scope = user_scope_fixture()
    %{scope: scope}
  end

  describe "eligibility/3" do
    test "ready with age, the go-ahead and the whole pre-flight list", %{scope: scope} do
      child = ready_child(scope)
      el = Plans.eligibility(child, phase(child), Date.utc_today())

      assert el.age == {:ok, nil}
      assert el.clearance == Date.utc_today()
      assert el.preflight == %{done: 8, total: 8, missing: []}
      assert el.ready?
    end

    test "a baby under 5 months is locked until the date they reach it", %{scope: scope} do
      child = ready_child(scope, %{birth_date: Date.add(Date.utc_today(), -100)})
      el = Plans.eligibility(child, phase(child), Date.utc_today())

      assert el.age == {:locked, Date.add(Date.utc_today(), 52)}
      refute el.ready?
    end

    test "corrected age counts for a baby born early", %{scope: scope} do
      # 170 days old but born 8 weeks early: only 114 days corrected.
      child = ready_child(scope, %{gestation_weeks: 32})
      el = Plans.eligibility(child, phase(child), Date.utc_today())
      assert {:locked, _} = el.age
    end

    test "needs the pediatrician's go-ahead", %{scope: scope} do
      child = ready_child(scope)

      {:ok, child} =
        Families.update_sleep_toolkit(scope, child, %{sleep_training_cleared_on: nil})

      el = Plans.eligibility(child, phase(child), Date.utc_today())

      assert el.clearance == nil
      refute el.ready?
    end

    test "names the pre-flight items still to tick", %{scope: scope} do
      child = ready_child(scope)
      {:ok, child} = Families.toggle_sleep_check(scope, child, "p-room", Date.utc_today())
      {:ok, child} = Families.toggle_sleep_check(scope, child, "p-well", Date.utc_today())
      el = Plans.eligibility(child, phase(child), Date.utc_today())

      assert el.preflight.done == 6
      assert Enum.sort(el.preflight.missing) == ["p-room", "p-well"]
      refute el.ready?
    end

    test "no phase (no birth date) is locked", %{scope: scope} do
      child = ready_child(scope)
      assert %{age: {:locked, nil}} = Plans.eligibility(child, nil, Date.utc_today())
    end
  end

  describe "start/4" do
    test "starts night 1 tonight when everything's in place", %{scope: scope} do
      child = ready_child(scope)
      Families.subscribe(child.id)

      assert {:ok, %Plan{} = plan} = Plans.start(scope, child, phase(child))
      assert plan.definition == :abcs
      assert plan.status == :active
      assert plan.started_on == Date.utc_today()
      assert plan.started_by_id == scope.user.id
      assert Plans.active(scope, child).id == plan.id
      assert_receive {:sleep_plan, :started, %{id: id}} when id == plan.id
    end

    test "stores the night-weaning setup", %{scope: scope} do
      child = ready_child(scope)

      {:ok, plan} =
        Plans.start(scope, child, phase(child), %{
          feed_kind: :bottle,
          feed_times: [1350, 210],
          feed_amounts: [120, 120]
        })

      assert %{feed_kind: :bottle, feed_times: [1350, 210], feed_amounts: [120, 120]} = plan
    end

    test "refuses when not ready", %{scope: scope} do
      child = child_fixture(scope, %{birth_date: Date.add(Date.utc_today(), -170)})
      assert {:error, :not_ready} = Plans.start(scope, child, phase(child))
      assert Plans.active(scope, child) == nil
    end

    test "only one plan at a time", %{scope: scope} do
      child = ready_child(scope)
      {:ok, _} = Plans.start(scope, child, phase(child))
      assert {:error, :already_active} = Plans.start(scope, child, phase(child))
    end

    test "rejects a malformed night-weaning setup", %{scope: scope} do
      child = ready_child(scope)

      assert {:error, cs} =
               Plans.start(scope, child, phase(child), %{
                 feed_kind: :bottle,
                 feed_times: [60],
                 feed_amounts: []
               })

      assert "needs an amount for each feed" in errors_on(cs).feed_amounts

      assert {:error, cs} =
               Plans.start(scope, child, phase(child), %{
                 feed_kind: :bottle,
                 feed_times: [60, 120, 180, 240],
                 feed_amounts: [1, 1, 1, 1]
               })

      assert "no more than three night feeds" in errors_on(cs).feed_times

      assert {:error, cs} =
               Plans.start(scope, child, phase(child), %{feed_times: [60], feed_amounts: [10]})

      assert "choose nursing or bottle" in errors_on(cs).feed_kind
    end

    test "viewers can't start one" do
      %{owner_scope: owner, child: child, member_scope: viewer} = shared_child_fixture(:viewer)

      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        Plans.start(viewer, child, %{age_days: 200})
      end

      _ = owner
    end
  end

  describe "finish/3, notes and listing" do
    test "finishing ends it, broadcasts, and lets another start", %{scope: scope} do
      child = ready_child(scope)
      {:ok, plan} = Plans.start(scope, child, phase(child))
      Families.subscribe(child.id)

      assert {:ok, %{status: :stopped, ended_on: ended}} = Plans.finish(scope, plan, :stopped)
      assert ended == Date.utc_today()
      assert Plans.active(scope, child) == nil
      assert_receive {:sleep_plan, :ended, _}

      assert {:ok, again} = Plans.start(scope, child, phase(child))
      assert again.id != plan.id
      assert Enum.map(Plans.list(scope, child), & &1.status) |> Enum.sort() == [:active, :stopped]
    end

    test "notes are kept by night and cleared with blank text", %{scope: scope} do
      child = ready_child(scope)
      {:ok, plan} = Plans.start(scope, child, phase(child))

      {:ok, plan} = Plans.put_note(scope, plan, 3, "  Woke twice  ")
      assert plan.notes == %{"3" => "Woke twice"}

      {:ok, plan} = Plans.put_note(scope, plan, 3, "   ")
      assert plan.notes == %{}
    end
  end

  describe "night_number/3" do
    setup %{scope: scope} do
      child = ready_child(scope, %{timezone: "Etc/UTC"})
      {:ok, plan} = Plans.start(scope, child, phase(child), %{started_on: ~D[2026-10-10]})
      %{child: child, plan: plan}
    end

    defp utc(date, time), do: DateTime.new!(date, time, "Etc/UTC")

    test "the evening of started_on is night 1, and the small hours belong to the evening before",
         %{
           child: child,
           plan: plan
         } do
      assert Plans.night_number(plan, child, utc(~D[2026-10-10], ~T[19:30:00])) == 1
      assert Plans.night_number(plan, child, utc(~D[2026-10-11], ~T[03:00:00])) == 1
      assert Plans.night_number(plan, child, utc(~D[2026-10-11], ~T[11:59:00])) == 1
      assert Plans.night_number(plan, child, utc(~D[2026-10-11], ~T[12:00:00])) == 2
      assert Plans.night_number(plan, child, utc(~D[2026-10-23], ~T[20:00:00])) == 14
      assert Plans.night_number(plan, child, utc(~D[2026-10-24], ~T[20:00:00])) == 15
    end

    test "before the plan starts it's night 0", %{child: child, plan: plan} do
      assert Plans.night_number(plan, child, utc(~D[2026-10-10], ~T[08:00:00])) == 0
      assert Plans.night_number(plan, child, utc(~D[2026-10-09], ~T[22:00:00])) == 0
    end

    test "night_date/2 is the evening date", %{plan: plan} do
      assert Plans.night_date(plan, 1) == ~D[2026-10-10]
      assert Plans.night_date(plan, 14) == ~D[2026-10-23]
    end

    test "uses the child's time zone", %{scope: scope} do
      child = ready_child(scope, %{timezone: "Etc/GMT+8"})
      {:ok, plan} = Plans.start(scope, child, phase(child), %{started_on: ~D[2026-10-10]})

      # 04:00 UTC is 20:00 the evening before at UTC-8: night 0 here.
      assert Plans.night_number(plan, child, utc(~D[2026-10-10], ~T[04:00:00])) == 0
      # 04:00 UTC the next day is 20:00 on the 10th: night 1.
      assert Plans.night_number(plan, child, utc(~D[2026-10-11], ~T[04:00:00])) == 1
    end
  end

  describe "tonight/3 and weaning_table/1" do
    setup %{scope: scope} do
      child = ready_child(scope, %{timezone: "Etc/UTC"})

      {:ok, plan} =
        Plans.start(scope, child, phase(child), %{
          started_on: ~D[2026-10-10],
          feed_kind: :nursing,
          feed_times: [1350, 210],
          feed_amounts: [15, 15]
        })

      %{child: child, plan: plan}
    end

    test "night 1: touch, the starting amounts", %{child: child, plan: plan} do
      tonight = Plans.tonight(plan, child, utc(~D[2026-10-10], ~T[19:00:00]))

      assert %{night: 1, nights: 14, touch: :touch, finished?: false, date: ~D[2026-10-10]} =
               tonight

      assert [%{time: 1350, amount: 15}, %{time: 210, amount: 15}] = tonight.weaning
    end

    test "night 3 is voice only, with smaller amounts", %{child: child, plan: plan} do
      tonight = Plans.tonight(plan, child, utc(~D[2026-10-12], ~T[19:00:00]))
      assert %{night: 3, touch: :voice} = tonight
      assert [%{amount: a}, %{amount: b}] = tonight.weaning
      assert a < 15 and b < 15
    end

    test "feeds are dropped by night 5", %{child: child, plan: plan} do
      tonight = Plans.tonight(plan, child, utc(~D[2026-10-14], ~T[19:00:00]))
      assert %{night: 5, weaning: [%{amount: nil}, %{amount: nil}]} = tonight
    end

    test "after night 14 it's finished", %{child: child, plan: plan} do
      assert %{finished?: true} = Plans.tonight(plan, child, utc(~D[2026-10-24], ~T[19:00:00]))
    end

    test "no weaning without night feeds", %{scope: scope} do
      child = ready_child(scope, %{timezone: "Etc/UTC"})
      {:ok, plan} = Plans.start(scope, child, phase(child), %{started_on: ~D[2026-10-10]})

      assert Plans.weaning_table(plan) == nil
      assert Plans.tonight(plan, child, utc(~D[2026-10-10], ~T[19:00:00])).weaning == []
    end
  end
end
