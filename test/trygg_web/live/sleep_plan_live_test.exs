defmodule TryggWeb.SleepPlanLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.FamiliesFixtures

  alias Trygg.Families
  alias Trygg.Families.Child
  alias Trygg.Sleep.{Abcs, NightWakes, Phase, Plans}

  defp old_child(scope, attrs \\ %{}),
    do:
      child_fixture(
        scope,
        Map.merge(%{birth_date: Date.add(Date.utc_today(), -170), timezone: "Etc/UTC"}, attrs)
      )

  # Clears the go-ahead and ticks the pre-flight list, so the plan can start.
  defp ready(scope, child) do
    {:ok, child} =
      Families.update_sleep_toolkit(scope, child, %{sleep_training_cleared_on: Date.utc_today()})

    checks = Map.new(Abcs.preflight_ids(), &{&1, Date.to_iso8601(Date.utc_today())})
    {:ok, child} = Families.update_sleep_toolkit(scope, child, %{sleep_checks: checks})
    child
  end

  # A plan whose current night is `night` right now.
  defp start_plan(scope, child, night, attrs \\ %{}) do
    now = DateTime.utc_now()
    local = DateTime.shift_zone!(now, child.timezone)

    evening =
      if local.hour < 12, do: Date.add(DateTime.to_date(local), -1), else: DateTime.to_date(local)

    {:ok, plan} =
      Plans.start(
        scope,
        child,
        Phase.for_child(child),
        Map.put(attrs, :started_on, Date.add(evening, -(night - 1)))
      )

    plan
  end

  # The page suggests a gradual plan first; the ABCs are a click away.
  defp choose_abcs(lv), do: lv |> element("#approach-abcs") |> render_click()

  describe "auth and navigation" do
    test "anonymous users are sent to log in", %{conn: conn} do
      child = child_fixture()

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(conn, ~p"/c/#{child}/sleep/plan")
    end

    test "when sleep isn't tracked it sends you to Today", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      child = child_fixture(scope)
      {:ok, child} = Families.update_tracked_types(scope, child, [:diaper])
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/c/#{child}/sleep/plan")
      assert to == ~p"/c/#{child}"
    end

    test "is in the Sleep switch", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      child = old_child(scope)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
      assert has_element?(lv, "#subnav-plan[aria-current=page]")
    end
  end

  describe "a baby under 5 months" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})

      %{
        conn: conn,
        scope: scope,
        child: child_fixture(scope, %{birth_date: Date.add(Date.utc_today(), -100)})
      }
    end

    test "sees the plan explained and locked, with the date it opens", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
      choose_abcs(lv)

      assert has_element?(lv, "#abcs-intro", "14-night plan")
      assert has_element?(lv, "#abcs-gate-age", "5 months")

      assert has_element?(
               lv,
               "#abcs-gate-age",
               Calendar.strftime(Date.add(Date.utc_today(), 52), "%b %-d")
             )

      refute has_element?(lv, "#abcs-setup-form")
      refute has_element?(lv, "#abcs-tonight")
    end

    test "can't start one even by sending the event", %{conn: conn, scope: scope, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
      render_click(lv, "start_plan", %{"plan" => %{"count" => "0"}})
      assert Plans.active(scope, child) == nil
    end
  end

  describe "before starting" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: old_child(scope)}
    end

    test "shows the gates, the pre-flight list and a blocked start", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
      choose_abcs(lv)

      assert has_element?(lv, "#abcs-gate-age", "past 5 months")
      assert has_element?(lv, "#abcs-gate-clearance", "pediatrician")
      assert has_element?(lv, "#abcs-preflight-count", "0 of 8")
      assert has_element?(lv, "#start-plan[disabled]")
      assert has_element?(lv, "#start-plan-blocked")
    end

    test "recording the go-ahead and ticking the list unlocks Start", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
      choose_abcs(lv)

      lv |> element("#toggle-training-clearance") |> render_click()
      assert Families.get_child!(scope, child.id).sleep_training_cleared_on == Date.utc_today()
      assert has_element?(lv, "#abcs-gate-clearance", "Pediatrician OK recorded")
      assert has_element?(lv, "#start-plan[disabled]")

      for id <- Abcs.preflight_ids(), do: lv |> element("#check-#{id} button") |> render_click()

      assert has_element?(lv, "#abcs-preflight-count", "8 of 8")
      refute has_element?(lv, "#start-plan[disabled]")
      refute has_element?(lv, "#start-plan-blocked")
    end

    test "the go-ahead can be taken back", %{conn: conn, scope: scope, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
      choose_abcs(lv)
      lv |> element("#toggle-training-clearance") |> render_click()
      lv |> element("#toggle-training-clearance") |> render_click()
      assert Families.get_child!(scope, child.id).sleep_training_cleared_on == nil
    end

    test "starting with no night feeds begins the plan", %{conn: conn, scope: scope, child: child} do
      child = ready(scope, child)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
      choose_abcs(lv)

      lv |> form("#abcs-setup-form", plan: %{count: "0"}) |> render_submit()

      assert %{status: :active, feed_times: []} = Plans.active(scope, child)
      assert has_element?(lv, "#abcs-tonight")
      refute has_element?(lv, "#abcs-gates")
    end

    test "starting with two bottle feeds stores them and shows the weaning table", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      child = ready(scope, child)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
      choose_abcs(lv)

      lv |> form("#abcs-setup-form", plan: %{count: "2"}) |> render_change()
      assert has_element?(lv, "#setup-feed-1")
      assert has_element?(lv, "#setup-feed-2")
      refute has_element?(lv, "#setup-feed-3")

      lv
      |> form("#abcs-setup-form",
        plan: %{
          count: "2",
          kind: "bottle",
          time_1: "22:30",
          amount_1: "120",
          time_2: "03:30",
          amount_2: "120"
        }
      )
      |> render_submit()

      plan = Plans.active(scope, child)
      assert plan.feed_kind == :bottle
      assert plan.feed_times == [1350, 210]
      assert plan.feed_amounts == [120, 120]
      assert has_element?(lv, "#abcs-weaning-table", "22:30")
      assert has_element?(lv, "#abcs-weaning-table", "03:30")
    end

    test "nursing feeds are in minutes", %{conn: conn, scope: scope, child: child} do
      child = ready(scope, child)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
      choose_abcs(lv)
      lv |> form("#abcs-setup-form", plan: %{count: "1"}) |> render_change()

      lv
      |> form("#abcs-setup-form",
        plan: %{count: "1", kind: "nursing", time_1: "00:30", amount_1: "12"}
      )
      |> render_submit()

      assert %{feed_kind: :nursing, feed_times: [30], feed_amounts: [12]} =
               Plans.active(scope, child)

      assert has_element?(lv, "#abcs-weaning-table", "12 min")
    end

    test "missing feed details are refused", %{conn: conn, scope: scope, child: child} do
      child = ready(scope, child)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
      choose_abcs(lv)
      lv |> form("#abcs-setup-form", plan: %{count: "1"}) |> render_change()

      lv
      |> form("#abcs-setup-form", plan: %{count: "1", kind: "bottle", time_1: "", amount_1: ""})
      |> render_submit()

      assert Plans.active(scope, child) == nil
      assert render(lv) =~ "Check the feed times and amounts"
    end

    test "the nap signs are there with the N.A.P. steps", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
      choose_abcs(lv)
      assert has_element?(lv, "#abcs-naps #nap-signs li")
      assert has_element?(lv, "#nap-steps", "Naptime routine")
      assert has_element?(lv, "#nap-table")
    end
  end

  describe "while the plan runs" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      child = old_child(scope) |> then(&ready(scope, &1))
      %{conn: conn, scope: scope, child: child}
    end

    test "night 1 shows tonight's instructions with touch comfort", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      start_plan(scope, child, 1)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")

      assert has_element?(lv, "#abcs-tonight", "Night 1 of 14")
      assert has_element?(lv, "#abcs-comfort", "soothing touch")
      assert has_element?(lv, "#abcs-bedtime", "19:00–20:00")
      assert has_element?(lv, "#abcs-goal", "11–12 hours")
      assert has_element?(lv, "#abcs-open-night-mode[href='#{~p"/c/#{child}/sleep/night"}']")
    end

    test "night 3 onward is voice only", %{conn: conn, scope: scope, child: child} do
      start_plan(scope, child, 3)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")

      assert has_element?(lv, "#abcs-tonight", "Night 3 of 14")
      assert has_element?(lv, "#abcs-comfort", "only your voice")
    end

    test "tonight's night feeds come from the weaning table", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      start_plan(scope, child, 1, %{
        feed_kind: :nursing,
        feed_times: [1350, 210],
        feed_amounts: [15, 15]
      })

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")

      assert has_element?(lv, "#abcs-weaning", "22:30: 15 min")
      assert has_element?(lv, "#abcs-weaning", "03:30: 15 min")
    end

    test "feeds are gone by night 5", %{conn: conn, scope: scope, child: child} do
      start_plan(scope, child, 5, %{
        feed_kind: :nursing,
        feed_times: [1350, 210],
        feed_amounts: [15, 15]
      })

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
      assert has_element?(lv, "#abcs-weaning", "no feed")
    end

    test "the night chart fills from the wakings, with progress", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      plan = start_plan(scope, child, 1)

      {:ok, put_down} = NightWakes.start(scope, child, :abcs, kind: :bedtime, plan_id: plan.id)
      {:ok, put_down} = NightWakes.record(scope, put_down, "cry", 0)
      {:ok, put_down} = NightWakes.record(scope, put_down, "pop_in", 1)
      {:ok, _} = NightWakes.asleep(scope, put_down, 2)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")

      assert has_element?(lv, "#abcs-night-1", "1")
      assert has_element?(lv, "#abcs-chart")
      assert has_element?(lv, "#abcs-cry-1")
      assert has_element?(lv, "#abcs-progress")
    end

    test "a note is saved for tonight and shown in the chart", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      plan = start_plan(scope, child, 1)
      {:ok, wake} = NightWakes.start(scope, child, :abcs, kind: :bedtime, plan_id: plan.id)
      {:ok, _} = NightWakes.asleep(scope, wake, 0)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
      lv |> form("#abcs-note-form", %{note: "Two long cries"}) |> render_submit()

      assert Plans.active(scope, child).notes == %{"1" => "Two long cries"}
      assert has_element?(lv, "#abcs-chart", "Two long cries")
    end

    test "stopping the plan ends it and brings back the start screen", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      start_plan(scope, child, 2)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")

      lv |> element("#stop-plan") |> render_click()

      assert Plans.active(scope, child) == nil
      assert has_element?(lv, "#approach-picker")
      choose_abcs(lv)
      assert has_element?(lv, "#abcs-gates")
      assert [%{status: :stopped}] = Plans.list(scope, child)
    end

    test "after 14 nights it can be marked complete", %{conn: conn, scope: scope, child: child} do
      start_plan(scope, child, 15)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")

      assert has_element?(lv, "#abcs-finished")
      refute has_element?(lv, "#stop-plan")

      lv |> element("#finish-plan") |> render_click()
      assert [%{status: :completed}] = Plans.list(scope, child)
    end

    test "a partner working through a waking updates this page live", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      plan = start_plan(scope, child, 1)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
      refute has_element?(lv, "#abcs-chart", "pop-ins")

      {:ok, wake} = NightWakes.start(scope, child, :abcs, plan_id: plan.id)
      {:ok, wake} = NightWakes.record(scope, wake, "pop_in", 1)
      {:ok, _} = NightWakes.asleep(scope, wake, 2)

      assert has_element?(lv, "#abcs-chart", "1 pop-in,")
    end

    test "viewers see the plan but no controls", %{conn: conn, scope: owner, child: child} do
      start_plan(owner, child, 1)
      %{conn: conn, scope: viewer} = register_and_log_in_user(%{conn: conn})
      membership_fixture(child, viewer.user, :viewer)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
      assert has_element?(lv, "#abcs-tonight")
      refute has_element?(lv, "#stop-plan")
      refute has_element?(lv, "#abcs-open-night-mode")
      refute has_element?(lv, "#abcs-note-form")

      render_click(lv, "finish_plan", %{"status" => "stopped"})
      assert Plans.active(owner, child) != nil
    end
  end

  test "an unknown checklist id is ignored", %{conn: conn} do
    %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
    child = old_child(scope)
    {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")

    render_click(lv, "toggle_check", %{"id" => "nonsense"})
    assert %Child{sleep_checks: checks} = Families.get_child!(scope, child.id)
    assert checks == %{}
  end
end
