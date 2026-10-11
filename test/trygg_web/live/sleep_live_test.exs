defmodule TryggWeb.SleepLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.{Families, Log}

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

  describe "this week" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: child_fixture(scope)}
    end

    test "starts empty", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")
      assert has_element?(lv, "#sleep-habits-empty")
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
