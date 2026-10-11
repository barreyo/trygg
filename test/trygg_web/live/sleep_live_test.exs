defmodule TryggWeb.SleepLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.{Families, Log}
  alias Trygg.Families.Child

  describe "auth boundary" do
    test "redirects anonymous users to log in", %{conn: conn} do
      child = child_fixture()
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/c/#{child}/sleep")
    end

    test "a non-member is bounced", %{conn: conn} do
      child = child_fixture()
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => _}}}} =
               live(conn, ~p"/c/#{child}/sleep")
    end
  end

  describe "the tab" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: child_fixture(scope)}
    end

    test "is in both navs and marked current on its own page", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")

      assert has_element?(
               lv,
               "#bottom-nav a[aria-current=page][href='#{~p"/c/#{child}/sleep"}']",
               "Sleep"
             )

      assert has_element?(
               lv,
               "#side-nav a[aria-current=page][href='#{~p"/c/#{child}/sleep"}']",
               "Sleep"
             )

      {:ok, today, _html} = live_loaded(conn, ~p"/c/#{child}")
      assert has_element?(today, "#bottom-nav a[href='#{~p"/c/#{child}/sleep"}']", "Sleep")
      refute has_element?(today, "#sleep-hero")
      refute has_element?(today, "#cue-chips")
    end

    test "a newborn sees the phase, soothing steps, rhythm and the road ahead", %{
      conn: conn,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")

      assert has_element?(lv, "#sleep-hero-phase", "Newborn")
      assert has_element?(lv, "#sleep-phase-newborn[aria-current=step]")
      assert has_element?(lv, "#sleep-hero-next", "Foundations")

      assert has_element?(lv, "#cries-steps li", "Contain")
      assert lv |> element("#cries-steps") |> render() |> String.split("<li") |> length() == 6

      assert has_element?(lv, "#sleep-cue-guide #cue-guide-overtired", "Rigid body")
      assert has_element?(lv, "#master-schedule", "Dream feed")
      assert has_element?(lv, "#roadmap-newborn")
      assert has_element?(lv, "#roadmap-foundations")
      assert has_element?(lv, "#roadmap-beyond", "ABCs of Sleep")
    end

    test "a newborn sees what's typical at their age and how nights usually go", %{
      conn: conn,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")

      assert has_element?(lv, "#age-guide-table", "Naps a day")
      assert has_element?(lv, "#age-guide h2", "Birth to 6 weeks")
      assert has_element?(lv, "#age-guide-wake")
      assert has_element?(lv, "#newborn-nights li", "20 minutes")
      assert has_element?(lv, "#witching-hours summary")
    end

    test "an older baby sees the typical day but not the newborn nights", %{
      conn: conn,
      scope: scope
    } do
      older = child_fixture(scope, %{birth_date: Date.add(Date.utc_today(), -100)})
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{older}/sleep")

      assert has_element?(lv, "#age-guide h2", "3 to 6 months")
      refute has_element?(lv, "#newborn-nights")
    end

    test "with no birth date there's no typical day to show", %{conn: conn, scope: scope} do
      expecting =
        child_fixture(scope, %{
          birth_date: nil,
          expected_birth_date: Date.add(Date.utc_today(), 30)
        })

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{expecting}/sleep")
      assert has_element?(lv, "#age-guide-none")
    end

    test "the typical day compares their own numbers once there's history", %{
      conn: conn,
      scope: scope
    } do
      older = child_fixture(scope, %{birth_date: Date.add(Date.utc_today(), -100)})
      now = DateTime.utc_now()

      for days_ago <- 1..5 do
        start = DateTime.add(now, -days_ago * 86_400 - 3 * 3600, :second)

        {:ok, _} =
          Trygg.Log.create_entry(scope, older, :sleep, %{
            "started_at" => start,
            "ended_at" => DateTime.add(start, 3600, :second)
          })
      end

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{older}/sleep")
      assert has_element?(lv, "#age-guide-compare")
    end

    test "an older baby gets Foundations, without the newborn-only panels", %{
      conn: conn,
      scope: scope
    } do
      older = child_fixture(scope, %{birth_date: Date.add(Date.utc_today(), -100)})
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{older}/sleep")

      assert has_element?(lv, "#sleep-hero-phase", "Foundations")
      refute has_element?(lv, "#sleep-cries")
      refute has_element?(lv, "#sleep-rhythm")
      assert has_element?(lv, "#roadmap-foundations")
    end

    test "before birth there's no tab and the page waits for a birth date", %{
      conn: conn,
      scope: scope
    } do
      expecting =
        child_fixture(scope, %{
          birth_date: nil,
          expected_birth_date: Date.add(Date.utc_today(), 30)
        })

      {:ok, today, _html} = live_loaded(conn, ~p"/c/#{expecting}")
      refute has_element?(today, "#bottom-nav a[href='#{~p"/c/#{expecting}/sleep"}']")

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{expecting}/sleep")
      assert has_element?(lv, "#sleep-hero", "Starts once")
      refute has_element?(lv, "#sleep-phase-steps")
    end

    test "when sleep isn't tracked there's no tab, and the page sends you to Today", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, child} = Families.update_tracked_types(scope, child, [:diaper])

      {:ok, today, _html} = live_loaded(conn, ~p"/c/#{child}")
      refute has_element?(today, "#bottom-nav a[href='#{~p"/c/#{child}/sleep"}']")

      assert {:error, {:live_redirect, %{to: to, flash: %{"info" => msg}}}} =
               live(conn, ~p"/c/#{child}/sleep")

      assert to == ~p"/c/#{child}"
      assert msg =~ "isn't tracked"
    end
  end

  describe "right now" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: child_fixture(scope)}
    end

    test "a cue tapped before Start sleep is saved on that sleep", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")

      lv |> element("#cue-chip-ready") |> render_click()
      assert has_element?(lv, "#cue-chip-ready[aria-pressed=true]")
      assert has_element?(lv, "#cue-chip-tired[aria-pressed=false]")

      lv |> element("#start-sleep") |> render_click()
      assert [%{type: :sleep, data: %{"cue" => "ready"}}] = Log.running_timers(scope, child)

      assert has_element?(lv, "#stop-sleep")
      assert has_element?(lv, "#cue-chip-ready[aria-pressed=true]")
    end

    test "starting without a cue saves none, and tapping a set cue again clears it", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")

      lv |> element("#cue-chip-tired") |> render_click()
      lv |> element("#cue-chip-tired") |> render_click()
      refute has_element?(lv, "#cue-chip-tired[aria-pressed=true]")

      lv |> element("#start-sleep") |> render_click()
      assert [%{data: data}] = Log.running_timers(scope, child)
      refute Map.has_key?(data, "cue")
    end

    test "a cue can be set, changed and cleared while the baby sleeps", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")
      lv |> element("#start-sleep") |> render_click()

      lv |> element("#cue-chip-overtired") |> render_click()
      assert [%{data: %{"cue" => "overtired"}}] = Log.running_timers(scope, child)

      lv |> element("#cue-chip-tired") |> render_click()
      assert [%{data: %{"cue" => "tired"}}] = Log.running_timers(scope, child)

      lv |> element("#cue-chip-tired") |> render_click()
      assert [%{data: data}] = Log.running_timers(scope, child)
      refute Map.has_key?(data, "cue")
    end

    test "Stop ends the sleep and keeps its cue", %{conn: conn, scope: scope, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")
      lv |> element("#cue-chip-ready") |> render_click()
      lv |> element("#start-sleep") |> render_click()

      lv |> element("#stop-sleep") |> render_click()

      assert Log.running_timers(scope, child) == []

      assert [%{type: :sleep, ended_at: %DateTime{}, data: %{"cue" => "ready"}}] =
               Log.list_entries(scope, child)

      assert has_element?(lv, "#start-sleep")
    end

    test "a sleep started elsewhere shows up live", %{conn: conn, scope: scope, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")
      refute has_element?(lv, "#stop-sleep")

      {:ok, _} = Log.start_timer(scope, child, :sleep)
      assert render(lv) =~ "Stop sleep"
    end

    test "a viewer sees the state but has no controls", %{conn: conn} do
      owner = user_scope_fixture()
      child = child_fixture(owner)
      %{conn: conn, scope: viewer} = register_and_log_in_user(%{conn: conn})
      membership_fixture(child, viewer.user, :viewer)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")
      assert has_element?(lv, "#sleep-right-now")
      refute has_element?(lv, "#start-sleep")
      refute has_element?(lv, "#cue-chips")
    end
  end

  describe "today's schedule and insights" do
    # A child whose local time is about noon right now (a fixed-offset zone, so
    # no DST), with five regular days behind them (night 20:00–07:00 and naps at
    # 09:30, 12:30 and 15:30) and, today, a wake-up at 07:00 and one early nap.
    # That keeps the day's shape the same whenever the suite runs.
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      offset = rem(12 - DateTime.utc_now().hour + 24, 24)
      offset = if offset > 12, do: offset - 24, else: offset

      zone =
        cond do
          offset == 0 -> "Etc/UTC"
          offset > 0 -> "Etc/GMT-#{offset}"
          true -> "Etc/GMT+#{-offset}"
        end

      child = child_fixture(scope, %{timezone: zone})
      today = Child.local_today(child)
      local = &Child.at_local(child, &1, &2)

      sleep = fn date, from, to, end_date ->
        {:ok, _} =
          Log.create_entry(scope, child, :sleep, %{
            "started_at" => local.(date, from),
            "ended_at" => local.(end_date, to)
          })
      end

      for back <- 5..1//-1 do
        date = Date.add(today, -back)
        sleep.(date, ~T[20:00:00], ~T[07:00:00], Date.add(date, 1))
        sleep.(date, ~T[09:30:00], ~T[10:30:00], date)
        sleep.(date, ~T[12:30:00], ~T[13:30:00], date)
        sleep.(date, ~T[15:30:00], ~T[16:30:00], date)
      end

      sleep.(today, ~T[08:00:00], ~T[09:00:00], today)

      %{conn: conn, scope: scope, child: child}
    end

    test "lists what has happened and what's still to come", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")

      assert has_element?(lv, "#sleep-schedule #plan-wake[data-state=done]", "Woke up")
      assert has_element?(lv, "#plan-nap-1[data-state=done]", "08:00–09:00")
      assert has_element?(lv, "#plan-nap-2", "Nap 2")
      assert has_element?(lv, "#plan-nap-3[data-state=upcoming]", "Nap 3")
      assert has_element?(lv, "#plan-bed[data-state=upcoming]", "Bedtime")
      assert has_element?(lv, "#sleep-schedule-total")
    end

    test "the next nap is due when they've been awake longer than usual", %{
      conn: conn,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")

      assert has_element?(lv, "#plan-nap-2[data-state=due]", "Window is open")
      assert has_element?(lv, "#sleep-insights #insight-past-window[data-tone=watch]")
      assert has_element?(lv, "#insight-past-window", "C.R.I.E.S.")
    end

    test "summarises last night and charts the longest sleep of each night", %{
      conn: conn,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")

      assert has_element?(lv, "#sleep-overnight #night-slept", "11h 0m")
      assert has_element?(lv, "#night-longest", "11h 0m")
      assert has_element?(lv, "#night-wakings", "0")
      assert has_element?(lv, "#night-feeds", "0")

      # Five finished nights, one bar each.
      assert lv |> element("#overnight-bars") |> render() |> String.split("<li") |> length() == 6
      assert has_element?(lv, "#overnight-trend") == false
    end

    test "a sleep started now becomes the running nap, with the rest of the day after it", %{
      conn: conn,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")
      lv |> element("#start-sleep") |> render_click()

      assert has_element?(lv, "#plan-nap-2[data-state=now]", "Asleep")
      assert has_element?(lv, "#plan-nap-3[data-state=upcoming]")
      assert has_element?(lv, "#plan-bed")
      refute has_element?(lv, "#insight-past-window")
    end
  end

  describe "this week" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: child_fixture(scope)}
    end

    test "starts empty", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")
      assert has_element?(lv, "#sleep-habits-empty")
      assert has_element?(lv, "#sleep-schedule-empty")
      assert has_element?(lv, "#sleep-overnight-empty")
      assert has_element?(lv, "#sleep-insights")
    end

    test "counts cues and sleeps that began right after a feed", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, _feed} =
        Log.create_entry(scope, child, :feeding, %{
          "started_at" => DateTime.add(DateTime.utc_now(), -3, :minute),
          "data" => %{"amount_ml" => 60}
        })

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")
      lv |> element("#cue-chip-overtired") |> render_click()
      lv |> element("#start-sleep") |> render_click()

      assert has_element?(lv, "#stat-sleeps", "1")
      assert has_element?(lv, "#stat-cued", "1")
      assert has_element?(lv, "#stat-overtired", "1")
      assert has_element?(lv, "#stat-fed-to-sleep", "1 of 1")
    end
  end
end
