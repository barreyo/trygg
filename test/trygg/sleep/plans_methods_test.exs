defmodule Trygg.Sleep.PlansMethodsTest do
  @moduledoc "SLIP and SWAP running on the plan engine (`Trygg.Sleep.Plans`)."
  use Trygg.DataCase, async: true

  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.Families
  alias Trygg.Sleep.{Checkins, Definitions, Phase, Plan, Plans, Slip, Swap}

  defp child_aged(scope, days, attrs \\ %{}),
    do: child_fixture(scope, Map.merge(%{birth_date: Date.add(Date.utc_today(), -days)}, attrs))

  defp ticked(scope, child, ids) do
    checks = Map.new(ids, &{&1, Date.to_iso8601(Date.utc_today())})
    {:ok, child} = Families.update_sleep_toolkit(scope, child, %{sleep_checks: checks})
    child
  end

  defp cleared(scope, child) do
    {:ok, child} =
      Families.update_sleep_toolkit(scope, child, %{sleep_training_cleared_on: Date.utc_today()})

    child
  end

  defp phase(child), do: Phase.for_child(child)

  setup do
    %{scope: user_scope_fixture()}
  end

  describe "eligibility/4" do
    test "a SWAP opens at two months and needs no go-ahead", %{scope: scope} do
      child = scope |> child_aged(70) |> then(&ticked(scope, &1, Swap.preflight_ids()))
      el = Plans.eligibility(child, phase(child), Date.utc_today(), :swap)

      assert el.age == {:ok, nil}
      assert el.clearance == nil
      refute el.needs_clearance?
      assert el.preflight == %{done: 5, total: 5, missing: []}
      assert el.ready?
    end

    test "a SWAP is locked under two months, with the date", %{scope: scope} do
      child = child_aged(scope, 40)

      assert %{age: {:locked, date}} =
               Plans.eligibility(child, phase(child), Date.utc_today(), :swap)

      assert date == Date.add(Date.utc_today(), 21)
    end

    test "SLIP opens at four months and needs the go-ahead and all ten items", %{scope: scope} do
      child = child_aged(scope, 130)
      el = Plans.eligibility(child, phase(child), Date.utc_today(), :slip)
      assert el.age == {:ok, nil}
      assert el.needs_clearance?
      assert el.preflight.total == 10
      refute el.ready?

      child = scope |> cleared(child) |> then(&ticked(scope, &1, Slip.preflight_ids()))
      assert Plans.eligibility(child, phase(child), Date.utc_today(), :slip).ready?
    end

    test "SLIP is locked until four months", %{scope: scope} do
      child = child_aged(scope, 100)
      assert {:locked, _} = Plans.eligibility(child, phase(child), Date.utc_today(), :slip).age
    end

    test "ticking one plan's items doesn't count for another's", %{scope: scope} do
      child = child_aged(scope, 200)
      child = ticked(scope, child, Slip.preflight_ids())
      assert Plans.eligibility(child, phase(child), Date.utc_today(), :swap).preflight.done == 0
    end

    test "the default is still the ABCs", %{scope: scope} do
      child = child_aged(scope, 100)
      assert {:locked, _} = Plans.eligibility(child, phase(child), Date.utc_today()).age
    end
  end

  describe "starting a SWAP" do
    setup %{scope: scope} do
      child = scope |> child_aged(70) |> then(&ticked(scope, &1, Swap.preflight_ids()))
      %{child: child}
    end

    test "records the variant and where it started from", %{scope: scope, child: child} do
      Families.subscribe(child.id)

      assert {:ok, %Plan{definition: :swap, options: options} = plan} =
               Plans.start(scope, child, phase(child), %{
                 definition: :swap,
                 options: %{variant: "jiggle", start_minutes: 35}
               })

      assert options == %{"variant" => "jiggle", "start_minutes" => 35}
      assert Plans.active(scope, child).id == plan.id
      assert_receive {:sleep_plan, :started, _}
    end

    test "needs a real variant", %{scope: scope, child: child} do
      assert {:error, cs} =
               Plans.start(scope, child, phase(child), %{definition: :swap})

      assert "choose a variant" in errors_on(cs).options

      assert {:error, cs} =
               Plans.start(scope, child, phase(child), %{
                 definition: "swap",
                 options: %{"variant" => "nope"}
               })

      assert "choose a variant" in errors_on(cs).options
    end

    test "start minutes are bounded", %{scope: scope, child: child} do
      assert {:error, cs} =
               Plans.start(scope, child, phase(child), %{
                 definition: :swap,
                 options: %{"variant" => "pat", "start_minutes" => 500}
               })

      assert "start minutes must be between 1 and 120" in errors_on(cs).options
    end

    test "tonight carries the variant and its step", %{scope: scope, child: child} do
      {:ok, plan} =
        Plans.start(scope, child, phase(child), %{
          definition: :swap,
          options: %{"variant" => "pat", "start_minutes" => 30},
          started_on: Date.utc_today()
        })

      now = DateTime.utc_now()
      tonight = Plans.tonight(plan, child, now)

      assert %{definition: :swap, nights: 7, variant: %{id: :pat}} = tonight
      assert tonight.step.target_minutes in [30, 25]
      refute tonight.finished?
    end

    test "the chair runs ten nights", %{scope: scope, child: child} do
      {:ok, plan} =
        Plans.start(scope, child, phase(child), %{
          definition: :swap,
          options: %{"variant" => "chair"}
        })

      assert Definitions.nights(plan) == 10
      assert Plans.tonight(plan, child, DateTime.utc_now()).nights == 10
    end
  end

  describe "starting a SLIP" do
    setup %{scope: scope} do
      child =
        scope
        |> child_aged(140)
        |> then(&cleared(scope, &1))
        |> then(&ticked(scope, &1, Slip.preflight_ids()))

      %{child: child}
    end

    test "defaults to graduated visits", %{scope: scope, child: child} do
      assert {:ok, %Plan{definition: :slip, options: %{"mode" => "graduated"}} = plan} =
               Plans.start(scope, child, phase(child), %{definition: "slip"})

      tonight = Plans.tonight(plan, child, DateTime.utc_now())
      assert %{definition: :slip, mode: :graduated, nights: 7} = tonight
      assert tonight.visits == Slip.schedule(max(tonight.night, 1))
      assert tonight.expected == Slip.expected(max(tonight.night, 1))
    end

    test "a full SLIP has no visits", %{scope: scope, child: child} do
      {:ok, plan} =
        Plans.start(scope, child, phase(child), %{
          definition: :slip,
          options: %{mode: "full"}
        })

      assert %{mode: :full, visits: []} = Plans.tonight(plan, child, DateTime.utc_now())
    end

    test "rejects an unknown mode", %{scope: scope, child: child} do
      assert {:error, cs} =
               Plans.start(scope, child, phase(child), %{
                 definition: :slip,
                 options: %{"mode" => "whenever"}
               })

      assert "choose graduated or full" in errors_on(cs).options
    end

    test "can move from graduated to full, but not back", %{scope: scope, child: child} do
      {:ok, plan} = Plans.start(scope, child, phase(child), %{definition: :slip})
      Families.subscribe(child.id)

      assert {:ok, %{options: %{"mode" => "full"}} = full} = Plans.go_full(scope, plan)
      assert_receive {:sleep_plan, :changed, _}
      assert Definitions.schedule(full, 2) == :none

      # Going full again changes nothing, and there's no way back.
      assert {:ok, %{options: %{"mode" => "full"}}} = Plans.go_full(scope, full)
      refute function_exported?(Plans, :go_graduated, 2)
    end

    test "is refused without the go-ahead", %{scope: scope} do
      child = scope |> child_aged(140) |> then(&ticked(scope, &1, Slip.preflight_ids()))
      assert {:error, :not_ready} = Plans.start(scope, child, phase(child), %{definition: :slip})
    end
  end

  test "an unknown definition is refused", %{scope: scope} do
    child = child_aged(scope, 200)

    assert {:error, :not_ready} =
             Plans.start(scope, child, phase(child), %{definition: "mystery"})
  end

  describe "check-in timing by schedule" do
    @t0 ~U[2026-10-10 02:00:00Z]

    defp events(kinds) do
      for {kind, minutes} <- kinds, do: Checkins.event(kind, DateTime.add(@t0, minutes * 60))
    end

    test "the graduated SLIP's first visit is 5 minutes a night in" do
      now = DateTime.add(@t0, 60)

      assert %{next_due_at: due} =
               Checkins.state(events([{"cry", 0}]), now, {:five_minute, 3})

      assert due == DateTime.add(@t0, 15 * 60)

      after_visit = events([{"cry", 0}, {"pop_in", 15}])

      assert %{next_due_at: due} = Checkins.state(after_visit, now, {:five_minute, 3})
      assert due == DateTime.add(@t0, (15 + 20) * 60)
    end

    test "a full SLIP or a SWAP never has a visit due" do
      for schedule <- [:none, :manual] do
        assert %{phase: :crying, next_due_at: nil} =
                 Checkins.state(events([{"cry", 0}]), @t0, schedule)
      end
    end

    test "the ABCs schedule is still the default" do
      assert %{next_due_at: due} = Checkins.state(events([{"cry", 0}]), @t0)
      assert due == DateTime.add(@t0, 300)
    end
  end
end
