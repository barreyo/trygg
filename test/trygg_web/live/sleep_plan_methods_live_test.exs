defmodule TryggWeb.SleepPlanMethodsLiveTest do
  @moduledoc "Choosing and running a gradual plan (SWAP) or SLIP from the Sleep plan page and night mode."
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.FamiliesFixtures

  alias Trygg.Families
  alias Trygg.Sleep.{Abcs, NightWakes, Phase, Plans, Slip, Swap}

  defp child_aged(scope, days, timezone \\ "Etc/UTC"),
    do: child_fixture(scope, %{birth_date: Date.add(Date.utc_today(), -days), timezone: timezone})

  defp tick(scope, child, ids) do
    checks = Map.new(ids, &{&1, Date.to_iso8601(Date.utc_today())})
    {:ok, child} = Families.update_sleep_toolkit(scope, child, %{sleep_checks: checks})
    child
  end

  defp clear(scope, child) do
    {:ok, child} =
      Families.update_sleep_toolkit(scope, child, %{sleep_training_cleared_on: Date.utc_today()})

    child
  end

  # A plan whose current night is `night` right now.
  defp start_plan(scope, child, night, attrs) do
    local = DateTime.shift_zone!(DateTime.utc_now(), child.timezone)

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

  setup %{conn: conn} do
    %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
    %{conn: conn, scope: scope}
  end

  describe "choosing" do
    test "a baby under two months is told it's soothing, not teaching", %{
      conn: conn,
      scope: scope
    } do
      child = child_aged(scope, 30)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")

      assert has_element?(lv, "#approach-too-young")
      assert has_element?(lv, "#approach-swap span", "Locked")
      refute has_element?(lv, "#swap-intro")
    end

    test "a baby of three months is pointed at a gradual plan", %{conn: conn, scope: scope} do
      child = child_aged(scope, 100)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")

      assert has_element?(lv, "#approach-swap[data-suggested=true][aria-pressed=true]")
      assert has_element?(lv, "#approach-slip[data-suggested=false]")
      assert has_element?(lv, "#swap-intro")
      assert has_element?(lv, "#swap-gate-age", "past 2 months")
      assert has_element?(lv, "#swap-preflight-count", "0 of 5")
      refute has_element?(lv, "#swap-gate-clearance")
      assert has_element?(lv, "#swap-setup-form")
      assert has_element?(lv, "#start-swap[disabled]")
    end

    test "SLIP is locked with its date until four months", %{conn: conn, scope: scope} do
      child = child_aged(scope, 100)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")

      lv |> element("#approach-slip") |> render_click()

      assert has_element?(lv, "#slip-intro")
      assert has_element?(lv, "#slip-gate-age", "4 months")

      assert has_element?(
               lv,
               "#slip-gate-age",
               Calendar.strftime(Date.add(Date.utc_today(), 22), "%b %-d")
             )

      refute has_element?(lv, "#slip-setup-form")
    end

    test "after a gradual plan was stopped, SLIP is what's suggested", %{
      conn: conn,
      scope: scope
    } do
      child = scope |> child_aged(140) |> then(&tick(scope, &1, Swap.preflight_ids()))

      plan = start_plan(scope, child, 3, %{definition: :swap, options: %{"variant" => "pat"}})
      {:ok, _} = Plans.finish(scope, plan, :stopped)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
      assert has_element?(lv, "#approach-slip[data-suggested=true]")
      assert has_element?(lv, "#slip-intro")
    end

    test "the suggested gradual plan follows how they fall asleep", %{conn: conn, scope: scope} do
      child = child_aged(scope, 100)

      for level <- [2, 2, 3, 2] do
        {:ok, _} =
          Trygg.Log.create_entry(scope, child, :sleep, %{
            "started_at" => DateTime.add(DateTime.utc_now(), -3600, :second),
            "ended_at" => DateTime.add(DateTime.utc_now(), -1800, :second),
            "data" => %{"assist" => level}
          })
      end

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
      assert has_element?(lv, "#swap-variant option[selected][value=chair]")
      assert has_element?(lv, "#approach-why", "your body")
    end
  end

  describe "starting a gradual plan" do
    setup %{scope: scope} do
      %{child: scope |> child_aged(100) |> then(&tick(scope, &1, Swap.preflight_ids()))}
    end

    test "ticking the list opens Start, and the variant changes what's shown", %{
      conn: conn,
      scope: scope
    } do
      child = child_aged(scope, 100)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")

      for id <- Swap.preflight_ids(), do: lv |> element("#check-#{id} button") |> render_click()
      assert has_element?(lv, "#swap-preflight-count", "5 of 5")
      refute has_element?(lv, "#start-swap[disabled]")

      lv |> form("#swap-setup-form", %{"plan" => %{"variant" => "pat"}}) |> render_change()

      assert has_element?(lv, "#swap-summary", "drum")
      assert has_element?(lv, "#swap-start-minutes")

      lv |> form("#swap-setup-form", %{"plan" => %{"variant" => "chair"}}) |> render_change()

      assert has_element?(lv, "#swap-steps li", "two feet")
      refute has_element?(lv, "#swap-start-minutes")
    end

    test "starting records the variant and shows tonight's step", %{
      conn: conn,
      child: child,
      scope: scope
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")

      lv |> form("#swap-setup-form", %{"plan" => %{"variant" => "jiggle"}}) |> render_change()

      lv
      |> form("#swap-setup-form", %{"plan" => %{"variant" => "jiggle", "start_minutes" => "40"}})
      |> render_submit()

      assert %{definition: :swap, options: %{"variant" => "jiggle", "start_minutes" => 40}} =
               Plans.active(scope, child)

      assert has_element?(lv, "#swap-tonight")
      assert has_element?(lv, "#swap-name", "Jiggle the crib")
      assert has_element?(lv, "#swap-step", "40 minutes")
      assert has_element?(lv, "#swap-checks")
      assert has_element?(lv, "#plan-feed-rules")
      assert has_element?(lv, "#nap-master-plan")
      refute has_element?(lv, "#abcs-tonight")
      refute has_element?(lv, "#go-full")
    end

    test "a viewer sees the plan page without any setup", %{conn: conn} do
      owner = Trygg.AccountsFixtures.user_scope_fixture()
      child = child_aged(owner, 100)
      %{conn: conn, scope: viewer} = register_and_log_in_user(%{conn: conn})
      membership_fixture(child, viewer.user, :viewer)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
      assert has_element?(lv, "#swap-intro")
      refute has_element?(lv, "#swap-setup-form")
      refute has_element?(lv, "#check-w-routine button")
    end
  end

  describe "running a SWAP" do
    setup %{scope: scope} do
      child = scope |> child_aged(100) |> then(&tick(scope, &1, Swap.preflight_ids()))

      plan =
        start_plan(scope, child, 3, %{
          definition: :swap,
          options: %{"variant" => "pat", "start_minutes" => 30}
        })

      %{child: child, plan: plan}
    end

    test "shows the step for tonight, the chart without a crying column and the trend", %{
      conn: conn,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")

      assert has_element?(lv, "#swap-tonight h2", "Night 3 of 7")
      assert has_element?(lv, "#swap-step", "20 minutes")
      assert has_element?(lv, "#abcs-chart")
      refute has_element?(lv, "#abcs-chart th", "Crying")
      assert has_element?(lv, "#abcs-progress")
    end

    test "night mode puts down and times it, with no pop-in timer", %{
      conn: conn,
      scope: scope,
      child: child,
      plan: plan
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")

      assert has_element?(lv, "#night-idle h2", "Gradual (SWAP)")
      assert has_element?(lv, "#night-swap-step", "20 minutes")

      lv |> element("#abcs-put-down") |> render_click()
      assert has_element?(lv, "#abcs-waiting")
      lv |> element("#abcs-record-cry") |> render_click()

      refute has_element?(lv, "#night-countdown")
      assert has_element?(lv, "#abcs-no-timer")
      assert has_element?(lv, "#abcs-record-popin", "I went in")
      assert has_element?(lv, "#abcs-popin-how", "Tonight's step")

      lv |> element("#abcs-record-popin") |> render_click()
      assert has_element?(lv, "#abcs-cry-total", "times in: 1")

      lv |> element("#abcs-asleep") |> render_click()
      assert [%{kind: :bedtime, outcome: :settled}] = NightWakes.for_plan(scope, plan)
    end
  end

  describe "running a SLIP" do
    setup %{scope: scope} do
      # A midday zone, so these don't depend on the hour they run at: before
      # midday the small hours still count as last night, so "Night 1" wouldn't show.
      child =
        scope
        |> child_aged(150, Trygg.LogFixtures.midday_timezone())
        |> then(&clear(scope, &1))
        |> then(&tick(scope, &1, Slip.preflight_ids()))

      %{child: child}
    end

    test "starting with graduated visits (the default) shows tonight's visit times", %{
      conn: conn,
      child: child,
      scope: scope
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
      lv |> element("#approach-slip") |> render_click()

      assert has_element?(lv, "#slip-gate-clearance")
      assert has_element?(lv, "#slip-preflight-count", "10 of 10")
      assert has_element?(lv, "#slip-table #slip-night-3", "15")

      lv |> form("#slip-setup-form", %{"plan" => %{"mode" => "graduated"}}) |> render_submit()

      assert %{definition: :slip, options: %{"mode" => "graduated"}} = Plans.active(scope, child)
      assert has_element?(lv, "#slip-tonight h2", "Night 1 of 7")
      assert has_element?(lv, "#slip-visits", "5, 10, 15 minutes")
      assert has_element?(lv, "#slip-expect", "45–90 minutes")
      assert has_element?(lv, "#go-full")
      refute has_element?(lv, "#weaning-table")
    end

    test "a full SLIP has no visits", %{conn: conn, child: child, scope: scope} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
      lv |> element("#approach-slip") |> render_click()
      lv |> form("#slip-setup-form", %{"plan" => %{"mode" => "full"}}) |> render_submit()

      assert %{options: %{"mode" => "full"}} = Plans.active(scope, child)
      assert has_element?(lv, "#slip-full")
      refute has_element?(lv, "#slip-visits")
      refute has_element?(lv, "#go-full")
    end

    test "a graduated SLIP can go full, once", %{conn: conn, child: child, scope: scope} do
      start_plan(scope, child, 2, %{definition: :slip})
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")

      assert has_element?(lv, "#slip-visits", "10, 15, 20 minutes")
      lv |> element("#go-full") |> render_click()

      assert %{options: %{"mode" => "full"}} = Plans.active(scope, child)
      assert has_element?(lv, "#slip-full")
      refute has_element?(lv, "#go-full")
    end

    test "the nights are read: an extinction burst is named", %{
      conn: conn,
      child: child,
      scope: scope
    } do
      plan = start_plan(scope, child, 4, %{definition: :slip})

      for {night, minutes} <- [{1, 60}, {2, 20}, {3, 10}, {4, 45}] do
        date = Plans.night_date(plan, night)
        started = DateTime.new!(date, ~T[19:00:00], "Etc/UTC")

        {:ok, wake} =
          Trygg.Repo.insert(%Trygg.Sleep.NightWake{
            child_id: child.id,
            plan_id: plan.id,
            method: :abcs,
            kind: :bedtime,
            started_at: started,
            ended_at: DateTime.add(started, minutes * 60),
            step: 0,
            step_started_at: started,
            outcome: :settled,
            cry_seconds: minutes * 60,
            events: [
              Trygg.Sleep.Checkins.event("cry", started),
              Trygg.Sleep.Checkins.event("asleep", DateTime.add(started, minutes * 60))
            ]
          })

        assert wake.id
      end

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
      assert has_element?(lv, "#plan-assessment[data-status=burst]", "extinction burst")
    end

    test "night mode times visits by the night, and a full plan has no pop-in button", %{
      conn: conn,
      child: child,
      scope: scope
    } do
      start_plan(scope, child, 3, %{definition: :slip})
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")

      assert has_element?(lv, "#night-idle h2", "SLIP")
      lv |> element("#abcs-cry") |> render_click()
      assert has_element?(lv, "#abcs-state", "pop-in (1)")
      assert has_element?(lv, "#night-countdown[data-ends-at]")
      assert has_element?(lv, "#abcs-popin-how", "minute or two")

      # The first visit is due 15 minutes (night 3 × 5) after the crying began.
      wake = NightWakes.active(scope, child)
      [event] = wake.events
      {:ok, started, _} = DateTime.from_iso8601(event["at"])

      assert lv |> element("#night-countdown") |> render() =~
               "data-ends-at=\"#{(DateTime.to_unix(started) + 15 * 60) * 1000}\""
    end

    test "night mode on a full plan offers no visit", %{conn: conn, child: child, scope: scope} do
      start_plan(scope, child, 1, %{definition: :slip, options: %{"mode" => "full"}})
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")

      lv |> element("#abcs-cry") |> render_click()
      refute has_element?(lv, "#abcs-record-popin")
      refute has_element?(lv, "#night-countdown")
      assert has_element?(lv, "#abcs-no-timer", "Stay out")
      assert has_element?(lv, "#abcs-popin-how", "monitor")
      assert has_element?(lv, "#abcs-asleep")
    end
  end

  test "the ABCs plan still works beside the others", %{conn: conn, scope: scope} do
    child =
      scope
      |> child_aged(170)
      |> then(&clear(scope, &1))
      |> then(&tick(scope, &1, Abcs.preflight_ids()))

    {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/plan")
    lv |> element("#approach-abcs") |> render_click()
    assert has_element?(lv, "#abcs-intro")
    assert has_element?(lv, "#abcs-setup-form")

    lv |> form("#abcs-setup-form", %{"plan" => %{"count" => "0"}}) |> render_submit()
    assert %{definition: :abcs} = Plans.active(scope, child)
    assert has_element?(lv, "#abcs-tonight")
  end
end
