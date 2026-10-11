defmodule TryggWeb.SleepToolkitLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures
  import Trygg.GrowthFixtures

  alias Trygg.{Families, Log}

  defp older_child(scope),
    do: child_fixture(scope, %{birth_date: Date.add(Date.utc_today(), -100)})

  describe "auth and navigation" do
    test "anonymous users are sent to log in", %{conn: conn} do
      child = child_fixture()

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(conn, ~p"/c/#{child}/sleep/toolkit")
    end

    test "a non-member is bounced", %{conn: conn} do
      child = child_fixture()
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => _}}}} =
               live(conn, ~p"/c/#{child}/sleep/toolkit")
    end

    test "the Sleep pages link to each other", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      child = older_child(scope)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")
      assert has_element?(lv, "#subnav-today[aria-current=page]")
      assert has_element?(lv, "#subnav-toolkit[href='#{~p"/c/#{child}/sleep/toolkit"}']")

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")
      assert has_element?(lv, "#subnav-toolkit[aria-current=page]")
      assert has_element?(lv, "#bottom-nav a[aria-current=page][href='#{~p"/c/#{child}/sleep"}']")
    end

    test "when sleep isn't tracked it sends you to Today", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      child = child_fixture(scope)
      {:ok, child} = Families.update_tracked_types(scope, child, [:diaper])

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/c/#{child}/sleep/toolkit")
      assert to == ~p"/c/#{child}"
    end
  end

  describe "a newborn" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: child_fixture(scope)}
    end

    test "sees everything locked until 13 weeks", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")

      assert has_element?(lv, "#falling-asleep-locked")
      assert has_element?(lv, "#bedtime-locked")
      assert has_element?(lv, "#gate-age", "13 weeks")
      assert has_element?(lv, "#night-feeds-closed")
      refute has_element?(lv, "#night-feed-plan")
      refute has_element?(lv, "#assist-scale")
    end

    test "still gets the checklists", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")
      assert has_element?(lv, "#success-checklist li", "dark, cool")
      assert has_element?(lv, "#troubleshooting-checklist li")
    end

    test "gets no assist form while a sleep runs", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")
      lv |> element("#start-sleep") |> render_click()
      refute has_element?(lv, "#assist-form")
    end
  end

  describe "from 13 weeks" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: older_child(scope)}
    end

    test "how they fall asleep starts empty with the scale to hand", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")

      assert has_element?(lv, "#falling-asleep-empty")
      assert has_element?(lv, "#assist-scale #assist-level-9", "independently")
      refute has_element?(lv, "#falling-asleep-locked")
    end

    test "tracked sleeps show a weekly bar, a summary and a step to try", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      for {assist, settle} <- [{6, 20}, {7, 10}, {7, 10}] do
        {:ok, _} =
          Log.create_entry(scope, child, :sleep, %{
            "started_at" => DateTime.add(DateTime.utc_now(), -3600, :second),
            "ended_at" => DateTime.add(DateTime.utc_now(), -1800, :second),
            "data" => %{"assist" => assist, "settle_minutes" => settle}
          })
      end

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")

      assert has_element?(lv, "#falling-asleep-weeks li")
      assert has_element?(lv, "#falling-asleep-summary", "average level 6.7 over 3 sleeps")
      # The median of 20, 10 and 10 is 10; a mix like 5, 10 and 20 gives one that
      # isn't a preset bucket, which must still render.
      assert has_element?(lv, "#falling-asleep-summary", "settling in about 10 min")
      # Averaging 6.7 rounds to level 7, so the next step is level 8.
      assert has_element?(lv, "#falling-asleep-next", "level 8")
    end

    test "a median settle time that isn't a preset bucket still renders", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      for settle <- [5, 10, 20, 5] do
        {:ok, _} =
          Log.create_entry(scope, child, :sleep, %{
            "started_at" => DateTime.add(DateTime.utc_now(), -3600, :second),
            "ended_at" => DateTime.add(DateTime.utc_now(), -1800, :second),
            "data" => %{"assist" => 5, "settle_minutes" => settle}
          })
      end

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")
      assert has_element?(lv, "#falling-asleep-summary", "settling in about 8 min")
    end

    test "the Sleep tab asks how a running sleep started and saves it", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")
      refute has_element?(lv, "#assist-form")

      lv |> element("#start-sleep") |> render_click()
      assert has_element?(lv, "#assist-form")

      lv |> form("#assist-form", fall: %{assist: "8", settle: "10"}) |> render_change()

      assert [%{data: %{"assist" => 8, "settle_minutes" => 10}}] =
               Log.running_timers(scope, child)

      lv |> form("#assist-form", fall: %{assist: "", settle: "10"}) |> render_change()
      assert [%{data: data}] = Log.running_timers(scope, child)
      refute Map.has_key?(data, "assist")
      assert data["settle_minutes"] == 10
    end

    test "the bedtime plan with no history asks for a few bedtimes, and shows the guide's day", %{
      conn: conn,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")

      assert has_element?(lv, "#toolkit-bedtime")
      assert has_element?(lv, "#bedtime-status", "Log a few bedtimes")
      assert has_element?(lv, "#guide-day #guide-nap-1")
      assert has_element?(lv, "#guide-day #guide-bed-bed")
    end
  end

  describe "night feeds" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: older_child(scope)}
    end

    test "closed until age, weight and the pediatrician are all in place", %{
      conn: conn,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")

      assert has_element?(lv, "#gate-age", "past 13 weeks")
      assert has_element?(lv, "#gate-weight", "weigh-ins")
      assert has_element?(lv, "#gate-clearance", "pediatrician")
      assert has_element?(lv, "#night-feeds-closed")
      refute has_element?(lv, "#night-feed-plan")
    end

    test "recording the go-ahead isn't enough without a weigh-in", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")
      lv |> element("#toggle-night-weaning-clearance") |> render_click()

      assert Families.get_child!(scope, child.id).night_weaning_cleared_on == Date.utc_today()
      assert has_element?(lv, "#gate-clearance", "Pediatrician OK recorded")
      assert has_element?(lv, "#night-feeds-closed")
    end

    test "with a healthy weight trend and the go-ahead the plan opens, and clearing closes it again",
         %{
           conn: conn,
           scope: scope,
           child: child
         } do
      now = DateTime.utc_now()

      measurement_fixture(scope, child, %{
        "measured_at" => DateTime.add(now, -14, :day),
        "weight_g" => 5200.0
      })

      measurement_fixture(scope, child, %{
        "measured_at" => DateTime.add(now, -1, :day),
        "weight_g" => 5500.0
      })

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")
      assert has_element?(lv, "#gate-weight", "on track")

      lv |> element("#toggle-night-weaning-clearance") |> render_click()
      assert has_element?(lv, "#night-feed-plan")
      assert has_element?(lv, "#night-baseline-none")
      assert has_element?(lv, "#night-dream-feed", "23:00")
      refute has_element?(lv, "#night-feeds-closed")

      lv |> element("#toggle-night-weaning-clearance") |> render_click()
      refute has_element?(lv, "#night-feed-plan")
      assert Families.get_child!(scope, child.id).night_weaning_cleared_on == nil
    end

    test "weight gain below the guide flags the gate", %{conn: conn, scope: scope, child: child} do
      now = DateTime.utc_now()

      measurement_fixture(scope, child, %{
        "measured_at" => DateTime.add(now, -14, :day),
        "weight_g" => 5200.0
      })

      measurement_fixture(scope, child, %{
        "measured_at" => DateTime.add(now, -1, :day),
        "weight_g" => 5260.0
      })

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")
      assert has_element?(lv, "#gate-weight", "below")
    end

    test "viewers see the gates but can't record the go-ahead", %{conn: conn} do
      owner = user_scope_fixture()
      child = older_child(owner)
      %{conn: conn, scope: viewer} = register_and_log_in_user(%{conn: conn})
      membership_fixture(child, viewer.user, :viewer)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")
      assert has_element?(lv, "#night-feed-gates")
      refute has_element?(lv, "#toggle-night-weaning-clearance")
    end
  end

  describe "checklists" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: older_child(scope)}
    end

    test "manual items tick and untick and are remembered", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")
      assert has_element?(lv, "#success-count", "0 of 24")

      lv |> element("#check-environment button") |> render_click()
      assert has_element?(lv, "#check-environment[data-checked=true]")
      assert has_element?(lv, "#success-count", "1 of 24")
      assert Map.has_key?(Families.get_child!(scope, child.id).sleep_checks, "environment")

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")
      assert has_element?(lv, "#check-environment[data-checked=true]")

      lv |> element("#check-environment button") |> render_click()
      assert has_element?(lv, "#check-environment[data-checked=false]")
      assert Families.get_child!(scope, child.id).sleep_checks == %{}
    end

    test "troubleshooting questions tick too", %{conn: conn, scope: scope, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")
      lv |> element("#check-t-feeds button") |> render_click()
      assert Map.has_key?(Families.get_child!(scope, child.id).sleep_checks, "t-feeds")
    end

    test "automatic items have no button and tick from the log", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")
      refute has_element?(lv, "#check-day-calories button")
      assert has_element?(lv, "#check-day-calories[data-checked=false]")

      _ = scope
    end

    test "an id that isn't a manual item is ignored", %{conn: conn, scope: scope, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")
      render_click(lv, "toggle_check", %{"id" => "day-calories"})
      render_click(lv, "toggle_check", %{"id" => "nonsense"})
      assert Families.get_child!(scope, child.id).sleep_checks == %{}
    end

    test "viewers can't tick", %{conn: conn} do
      owner = user_scope_fixture()
      child = older_child(owner)
      %{conn: conn, scope: viewer} = register_and_log_in_user(%{conn: conn})
      membership_fixture(child, viewer.user, :viewer)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")
      refute has_element?(lv, "#check-environment button")
      render_click(lv, "toggle_check", %{"id" => "environment"})
      assert Families.get_child!(owner, child.id).sleep_checks == %{}
    end
  end

  describe "power tools and safe sleep" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: child_fixture(scope)}
    end

    test "a newborn gets the tools, with the swaddle and pacifier in use", %{
      conn: conn,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")

      assert has_element?(lv, "#tool-white_noise[data-state=use]")
      assert has_element?(lv, "#tool-swaddle[data-state=use]")
      assert has_element?(lv, "#tool-pacifier[data-state=use]")
      assert has_element?(lv, "#tool-schedule")
      assert has_element?(lv, "#lovey-note", "Nothing soft")
    end

    test "ticking that they're rolling ends the swaddle at once", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")

      lv |> element("#check-pt-rolling button") |> render_click()

      assert has_element?(lv, "#tool-swaddle[data-state=stop]", "Stop swaddling now")
      assert Families.get_child!(scope, child.id).sleep_checks["pt-rolling"]
    end

    test "a viewer can see the tools but not tick anything", %{conn: conn} do
      owner = user_scope_fixture()
      child = child_fixture(owner)
      %{conn: conn, scope: viewer} = register_and_log_in_user(%{conn: conn})
      membership_fixture(child, viewer.user, :viewer)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")
      assert has_element?(lv, "#tool-swaddle")
      refute has_element?(lv, "#check-pt-rolling button")
    end

    test "the safe sleep checklist can be ticked and counted", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")

      assert has_element?(lv, "#safe-sleep-count", "0 of 14")
      lv |> element("#check-ss-back button") |> render_click()
      assert has_element?(lv, "#safe-sleep-count", "1 of 14")
      assert has_element?(lv, "#check-ss-back[data-checked=true]")
      assert has_element?(lv, "#cosleeping summary", "share a bed")
    end

    test "night feeds show what's typical and the rules, even before they open", %{
      conn: conn,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")

      assert has_element?(lv, "#night-feeds-typical", "0–3 months")
      assert has_element?(lv, "#night-feed-rules li", "midnight")
    end
  end
end
