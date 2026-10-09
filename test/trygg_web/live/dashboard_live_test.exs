defmodule TryggWeb.DashboardLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.{Families, Log}

  # A "-N minute" quick-time chip bakes `now() - N*60` into the form at click
  # time, then round-trips through a minute-granularity datetime-local input.
  # `before`/`after_` must bracket the click itself (captured immediately
  # around the `render_click` call) — asserting only what that ordering
  # guarantees keeps this immune to CI scheduler jitter, however long the
  # click itself takes to actually run.
  defp assert_nudged_to(before, after_, entry_time, offset_seconds) do
    assert DateTime.diff(after_, entry_time, :second) >= offset_seconds
    assert DateTime.diff(after_, entry_time, :second) < offset_seconds + 300
    assert DateTime.diff(before, entry_time, :second) < offset_seconds + 60
  end

  describe "auth boundary" do
    test "GET / redirects anonymous users to log in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live_loaded(conn, ~p"/")
    end

    test "a non-member is bounced from a child dashboard", %{conn: conn} do
      child = child_fixture()
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => msg}}}} =
               live(conn, ~p"/c/#{child}")

      assert msg =~ "hasn't been shared with you"
    end
  end

  describe "onboarding" do
    setup :register_and_log_in_user

    test "/ sends a user with no children to add one", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/children/new"}}} = live_loaded(conn, ~p"/")
    end

    test "/ opens the first child for a user who has one", %{conn: conn, scope: scope} do
      child = child_fixture(scope)
      assert {:error, {:live_redirect, %{to: path}}} = live_loaded(conn, ~p"/")
      assert path == ~p"/c/#{child}"
    end

    test "/ reopens the child the caregiver was last looking at", %{conn: conn, scope: scope} do
      ada = child_fixture(scope, %{name: "Ada"})
      ollie = child_fixture(scope, %{name: "Ollie"})

      for pick <- [ollie, ada, ollie] do
        {:ok, _lv, _html} = live_loaded(conn, ~p"/c/#{pick}")
        assert {:error, {:live_redirect, %{to: path}}} = live_loaded(conn, ~p"/")
        assert path == ~p"/c/#{pick}"
      end
    end

    test "/ falls back to the newest child when the remembered one is gone", %{
      conn: conn,
      scope: scope
    } do
      gone = child_fixture(scope, %{name: "Gone"})
      keeper = child_fixture(scope, %{name: "Keeper"})

      {:ok, _lv, _html} = live_loaded(conn, ~p"/c/#{gone}")
      {:ok, _} = Families.delete_child(scope, gone)

      assert {:error, {:live_redirect, %{to: path}}} = live_loaded(conn, ~p"/")
      assert path == ~p"/c/#{keeper}"
    end
  end

  describe "header menu" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: child_fixture(scope)}
    end

    test "opens children management from the dashboard", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      assert has_element?(lv, "#app-menu")
      assert has_element?(lv, "#app-menu-children", "Children")
      assert has_element?(lv, "#app-menu-preferences", "Preferences")

      {:ok, children_lv, _html} =
        lv
        |> element("#app-menu-children")
        |> render_click()
        |> follow_redirect(conn, ~p"/children")

      assert await_load(children_lv) =~ child.name
    end

    test "opens preferences from the dashboard", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      {:ok, _prefs_lv, html} =
        lv
        |> element("#app-menu-preferences")
        |> render_click()
        |> follow_redirect(conn, ~p"/preferences")

      assert html =~ "Measurement units"
    end

    test "carries the account-level actions", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      assert has_element?(lv, "#app-menu-account[href='/users/settings']", "Account")
      assert has_element?(lv, "#app-menu-log-out[data-method=delete]", "Log out")
    end

    test "lets an owner edit the child and manage sharing", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      assert has_element?(lv, "#app-menu-sharing[href='#{~p"/c/#{child}/caregivers"}']")

      {:ok, _edit_lv, html} =
        lv
        |> element("#app-menu-edit-child")
        |> render_click()
        |> follow_redirect(conn, ~p"/children/#{child}/edit")

      assert html =~ "Edit #{child.name}"
    end

    test "hides editing from non-owners", %{conn: conn} do
      %{child: child, member: member} = shared_child_fixture(:caregiver)
      conn = log_in_user(conn, member)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      assert has_element?(lv, "#app-menu-sharing")
      refute has_element?(lv, "#app-menu-edit-child")
    end
  end

  describe "bottom tab bar" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: child_fixture(scope)}
    end

    test "shows the child's tabs on child pages", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      assert has_element?(lv, "#bottom-nav a[href='#{~p"/c/#{child}"}']", "Home")
      assert has_element?(lv, "#bottom-nav a[href='#{~p"/c/#{child}/log"}']", "Log")
      assert has_element?(lv, "#bottom-nav a[href='#{~p"/c/#{child}/vitals"}']", "Vitals")
      assert has_element?(lv, "#bottom-nav a[href='#{~p"/c/#{child}/reports"}']", "Reports")
    end

    test "has a desktop sidebar with the same tabs, marking the current one", %{
      conn: conn,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/vitals")

      assert has_element?(lv, "#side-nav a[href='#{~p"/c/#{child}"}']", "Home")
      assert has_element?(lv, "#side-nav a[href='#{~p"/c/#{child}/log"}']", "Log")
      assert has_element?(lv, "#side-nav a[href='#{~p"/c/#{child}/reports"}']", "Reports")

      assert has_element?(
               lv,
               "#side-nav a[aria-current=page][href='#{~p"/c/#{child}/vitals"}']",
               "Vitals"
             )
    end

    test "is replaced by a back arrow on account-level pages", %{conn: conn} do
      for path <- [~p"/preferences", ~p"/children", ~p"/users/settings"] do
        {:ok, lv, _html} = live_loaded(conn, path)

        refute has_element?(lv, "#bottom-nav")
        refute has_element?(lv, "#side-nav")
        assert has_element?(lv, "header a[aria-label=Back][href='/']")
        assert has_element?(lv, "#app-menu")
      end
    end
  end

  describe "child switcher" do
    setup :register_and_log_in_user

    test "is hidden when the user has only one child", %{conn: conn, scope: scope} do
      child = child_fixture(scope)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      refute has_element?(lv, "#child-switcher")
      assert has_element?(lv, "header", child.name)
    end

    test "names every child, marks the current one, and switches", %{conn: conn, scope: scope} do
      ada = child_fixture(scope, %{name: "Ada"})
      ollie = child_fixture(scope, %{name: "Ollie"})
      {:ok, lv, html} = live_loaded(conn, ~p"/c/#{ada}")

      assert has_element?(lv, "#child-switcher-trigger", "Ada")
      assert html =~ "Switch child, currently Ada"
      assert has_element?(lv, "#child-switcher-#{ada.id}[aria-current=page]", "Ada")
      assert has_element?(lv, "#child-switcher-#{ollie.id}", "Ollie")
      refute has_element?(lv, "#child-switcher-#{ollie.id}[aria-current=page]")

      {:ok, switched, switched_html} =
        lv
        |> element("#child-switcher-#{ollie.id}")
        |> render_click()
        |> follow_redirect(conn, ~p"/c/#{ollie}")

      assert has_element?(switched, "#child-switcher-trigger", "Ollie")
      assert switched_html =~ "Switch child, currently Ollie"
      assert has_element?(switched, "#child-switcher-#{ollie.id}[aria-current=page]")
    end
  end

  describe "logging" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: child_fixture(scope)}
    end

    test "a one-tap diaper button records an entry", %{conn: conn, scope: scope, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      lv |> element(~s(button[phx-value-kind="diaper_pee"])) |> render_click()

      assert render(lv) =~ "Pee diaper"
      assert [%{type: :diaper}] = Log.list_entries(scope, child)
    end

    test "a past diaper can be logged through the sheet", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      lv |> element("button", "Log from earlier") |> render_click()
      lv |> element(~s(button[phx-value-kind="diaper_past"])) |> render_click()

      earlier =
        DateTime.utc_now()
        |> DateTime.add(-2 * 3600, :second)
        |> Calendar.strftime("%Y-%m-%dT%H:%M")

      lv
      |> form("#diaper-form", entry: %{kind: "poo", started_at: earlier, note: "at grandma's"})
      |> render_submit()

      assert [%{type: :diaper, data: %{"kind" => "poo"}, note: "at grandma's"} = entry] =
               Log.list_entries(scope, child)

      assert DateTime.diff(DateTime.utc_now(), entry.started_at, :second) > 3600
      assert render(lv) =~ "Poo diaper"
    end

    test "the quick time chip back-dates a past diaper", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      lv |> element("button", "Log from earlier") |> render_click()
      lv |> element(~s(button[phx-value-kind="diaper_past"])) |> render_click()

      before_click = DateTime.utc_now()

      lv
      |> element(~s(button[phx-value-field="started_at"][phx-value-by="-15"]))
      |> render_click()

      after_click = DateTime.utc_now()

      lv |> form("#diaper-form", entry: %{kind: "pee", note: ""}) |> render_submit()

      assert [%{type: :diaper} = entry] = Log.list_entries(scope, child)
      assert_nudged_to(before_click, after_click, entry.started_at, 900)
    end

    test "a future diaper time is rejected", %{conn: conn, scope: scope, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      lv |> element("button", "Log from earlier") |> render_click()
      lv |> element(~s(button[phx-value-kind="diaper_past"])) |> render_click()

      later =
        DateTime.utc_now()
        |> DateTime.add(3600, :second)
        |> Calendar.strftime("%Y-%m-%dT%H:%M")

      html =
        lv
        |> form("#diaper-form", entry: %{kind: "pee", started_at: later, note: ""})
        |> render_submit()

      assert html =~ "in the future"
      assert Log.list_entries(scope, child) == []
    end

    test "logging a bottle through the sheet records a feed", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      lv |> element("button", "Log a bottle") |> render_click()
      lv |> element(~s(button[phx-value-by="60"])) |> render_click()
      lv |> element(~s(button[phx-value-by="30"])) |> render_click()
      lv |> form("#bottle-form", entry: %{bottle_contents: "formula"}) |> render_submit()

      assert [
               %{type: :feeding, data: %{"amount_ml" => 90.0, "bottle_contents" => "formula"}} =
                 feed
             ] =
               Log.list_entries(scope, child)

      assert feed.ended_at == feed.started_at
      assert render(lv) =~ "Bottle"
      assert render(lv) =~ "90 ml"
    end

    test "an exact small amount can be typed directly into the bottle sheet", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      lv |> element("button", "Log a bottle") |> render_click()

      lv
      |> form("#bottle-form", entry: %{amount: "28", bottle_contents: "formula"})
      |> render_submit()

      assert [%{type: :feeding, data: %{"amount_ml" => 28.0, "bottle_contents" => "formula"}}] =
               Log.list_entries(scope, child)
    end

    test "the fine +/- steps nudge the bottle amount by a small increment", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      lv |> element("button", "Log a bottle") |> render_click()
      lv |> element(~s(button[phx-click="bump_amount"][phx-value-by="5"])) |> render_click()
      lv |> element(~s(button[phx-click="bump_amount"][phx-value-by="5"])) |> render_click()

      assert has_element?(lv, "input#bottle-amount[value='10']")

      lv |> element(~s(button[phx-click="bump_amount"][phx-value-by="-5"])) |> render_click()

      assert has_element?(lv, "input#bottle-amount[value='5']")

      lv |> form("#bottle-form", entry: %{bottle_contents: "formula"}) |> render_submit()

      assert [%{data: %{"amount_ml" => 5.0}}] = Log.list_entries(scope, child)
    end

    test "a bottle can be back-dated through the sheet", %{conn: conn, scope: scope, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      lv |> element("button", "Log a bottle") |> render_click()
      lv |> element(~s(button[phx-value-by="60"])) |> render_click()

      earlier =
        DateTime.utc_now()
        |> DateTime.add(-90 * 60, :second)
        |> Calendar.strftime("%Y-%m-%dT%H:%M")

      lv
      |> form("#bottle-form",
        entry: %{bottle_contents: "formula", at: earlier, note: "sleepy feed"}
      )
      |> render_submit()

      assert [%{type: :feeding, note: "sleepy feed"} = feed] = Log.list_entries(scope, child)
      assert feed.ended_at == feed.started_at
      assert DateTime.diff(DateTime.utc_now(), feed.started_at, :second) > 3600
    end

    test "a future bottle time is rejected", %{conn: conn, scope: scope, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      lv |> element("button", "Log a bottle") |> render_click()
      lv |> element(~s(button[phx-value-by="60"])) |> render_click()

      later =
        DateTime.utc_now()
        |> DateTime.add(3600, :second)
        |> Calendar.strftime("%Y-%m-%dT%H:%M")

      html =
        lv
        |> form("#bottle-form", entry: %{bottle_contents: "formula", at: later})
        |> render_submit()

      assert html =~ "in the future"
      assert Log.list_entries(scope, child) == []
    end

    test "the bottle sheet pre-fills the last feed's amount", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      Trygg.LogFixtures.entry_fixture(scope, child, %{
        :type => :feeding,
        "data" => %{"bottle_contents" => "expressed", "amount_ml" => 120}
      })

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      html = lv |> element("button", "Log a bottle") |> render_click()
      assert html =~ "120"

      # saving without touching the amount reuses it
      lv |> form("#bottle-form", entry: %{}) |> render_submit()

      assert [%{data: %{"amount_ml" => 120.0}}, _older] = Log.list_entries(scope, child)
    end

    test "one tap starts a sleep timer; Stop asks for an end time and note", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      lv |> element("button", "Start sleep") |> render_click()
      assert [%{type: :sleep, ended_at: nil}] = Log.running_timers(scope, child)
      assert render(lv) =~ "Sleeping"

      lv |> element("button", "Stop") |> render_click()
      html = render(lv)
      assert html =~ "How did they sleep?"
      assert html =~ "Woke up at"

      lv
      |> form("#sleep-form", sleep: %{note: "slept great"})
      |> render_submit()

      assert [%{type: :sleep, ended_at: %DateTime{}, note: "slept great"}] =
               Log.list_entries(scope, child)

      assert Log.running_timers(scope, child) == []
    end

    test "the recent list shows a gentle \"Sleeping\" state while a nap is running", %{
      conn: conn,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      lv |> element("button", "Start sleep") |> render_click()

      html = render(lv)
      assert html =~ "Sleeping"
      assert html =~ ~s(class="snooze")
      refute html =~ "Sleep · running"

      lv |> element("button", "Stop") |> render_click()
      lv |> form("#sleep-form", sleep: %{}) |> render_submit()

      refute render(lv) =~ ~s(class="snooze")
      assert render(lv) =~ "Slept"
    end

    test "nudging the start moves a running timer's start time back", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      lv |> element("button", "Start sleep") |> render_click()

      [nap] = Log.running_timers(scope, child)
      lv |> element(~s(button[phx-value-by="-15"])) |> render_click()

      [moved] = Log.running_timers(scope, child)
      assert DateTime.diff(nap.started_at, moved.started_at, :second) in 895..905
      assert moved.ended_at == nil
    end

    test "Edit start lets you set a past start time for a running timer", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      lv |> element("button", "Start sleep") |> render_click()

      past = DateTime.utc_now() |> DateTime.add(-2, :hour) |> Calendar.strftime("%Y-%m-%dT%H:%M")

      lv |> element("button", "Edit") |> render_click()
      lv |> form("#sleep-form", sleep: %{started_at: past}) |> render_submit()

      [nap] = Log.running_timers(scope, child)
      assert DateTime.diff(DateTime.utc_now(), nap.started_at, :second) in 7000..7300
    end

    test "Log a past sleep records a completed range retroactively", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      now = DateTime.utc_now()
      started = now |> DateTime.add(-90, :minute) |> Calendar.strftime("%Y-%m-%dT%H:%M")
      ended = now |> DateTime.add(-15, :minute) |> Calendar.strftime("%Y-%m-%dT%H:%M")

      lv |> element("button", "Log from earlier") |> render_click()
      lv |> element(~s(button[phx-value-kind="sleep_past"])) |> render_click()

      lv
      |> form("#sleep-form",
        sleep: %{started_at: started, ended_at: ended, note: "in the carrier"}
      )
      |> render_submit()

      assert [%{type: :sleep, ended_at: %DateTime{}, note: "in the carrier"} = nap] =
               Log.list_entries(scope, child)

      assert DateTime.diff(nap.ended_at, nap.started_at, :second) in 4400..4600
      assert Log.running_timers(scope, child) == []
    end

    test "the quick time chips back-date a past sleep's start and end", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      lv |> element("button", "Log from earlier") |> render_click()
      lv |> element(~s(button[phx-value-kind="sleep_past"])) |> render_click()

      before_start = DateTime.utc_now()

      lv
      |> element(~s(button[phx-value-field="started_at"][phx-value-by="-30"]))
      |> render_click()

      after_start = DateTime.utc_now()
      before_end = DateTime.utc_now()

      lv
      |> element(~s(button[phx-value-field="ended_at"][phx-value-by="-5"]))
      |> render_click()

      after_end = DateTime.utc_now()

      lv |> form("#sleep-form", sleep: %{note: "quick chips"}) |> render_submit()

      assert [%{type: :sleep, ended_at: %DateTime{}, note: "quick chips"} = nap] =
               Log.list_entries(scope, child)

      assert_nudged_to(before_start, after_start, nap.started_at, 1800)
      assert_nudged_to(before_end, after_end, nap.ended_at, 300)
      assert DateTime.diff(nap.ended_at, nap.started_at, :second) in 1450..1550
    end

    test "a past sleep with the end before the start is rejected", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      now = DateTime.utc_now()
      started = now |> Calendar.strftime("%Y-%m-%dT%H:%M")
      ended = now |> DateTime.add(-30, :minute) |> Calendar.strftime("%Y-%m-%dT%H:%M")

      lv |> element("button", "Log from earlier") |> render_click()
      lv |> element(~s(button[phx-value-kind="sleep_past"])) |> render_click()

      html =
        lv
        |> form("#sleep-form", sleep: %{started_at: started, ended_at: ended})
        |> render_submit()

      assert html =~ "after they fell asleep"
    end

    test "a running sleep timer is visible to another caregiver and survives a reconnect", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      # caregiver A (the connected LV) starts a nap
      {:ok, lv_a, _html} = live_loaded(conn, ~p"/c/#{child}")
      lv_a |> element("button", "Start sleep") |> render_click()

      # caregiver B opens the dashboard fresh (as if returning after closing the app)
      other = user_fixture()
      membership_fixture(child, other, :caregiver)
      conn_b = log_in_user(Phoenix.ConnTest.build_conn(), other)

      {:ok, lv_b, html_b} = live_loaded(conn_b, ~p"/c/#{child}")
      assert html_b =~ "Asleep"
      assert html_b =~ ~s(phx-hook="Timer")

      # while asleep the sleep card gets its drifting Zzz and the success tone
      assert has_element?(lv_b, "#glance-sleep .glance-card[data-tone='success'] .glance-snooze")

      # and it's the same server-side timer, not a new one
      assert [%{type: :sleep, ended_at: nil}] = Log.running_timers(scope, child)
    end

    test "tapping a recent entry opens it for editing", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      entry = Trygg.LogFixtures.entry_fixture(scope, child, type: :diaper)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      lv |> element(~s([id$="#{entry.id}"])) |> render_click()

      assert has_element?(lv, "#edit-entry-form")

      lv
      |> form("#edit-entry-form", entry: %{note: "leaked"})
      |> render_submit()

      assert Log.get_entry!(scope, entry.id).note == "leaked"
      refute has_element?(lv, "#edit-entry-form")
    end

    test "deleting from recent removes the entry", %{conn: conn, scope: scope, child: child} do
      entry = Trygg.LogFixtures.entry_fixture(scope, child, type: :diaper)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      lv |> element(~s([id$="#{entry.id}"])) |> render_click()
      lv |> element("#edit-entry-delete") |> render_click()

      assert Log.list_entries(scope, child) == []
      refute has_element?(lv, "#edit-entry-form")
    end

    test "an entry logged by another caregiver appears live", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      other = user_fixture()
      membership_fixture(child, other, :caregiver)
      other_scope = Trygg.Accounts.Scope.for_user(other)

      {:ok, _} =
        Log.create_entry(other_scope, child, :feeding, %{
          "data" => %{"amount_ml" => 90, "bottle_contents" => "formula"}
        })

      html = render(lv)
      assert html =~ "Bottle"
      assert html =~ "90 ml"
    end
  end

  describe "remote update pulse" do
    import Trygg.LogFixtures

    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: child_fixture(scope)}
    end

    test "an entry logged elsewhere pulses its glance card and row", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      # The test process stands in for another device: it isn't the LiveView.
      entry = entry_fixture(scope, child, type: :diaper)

      assert_push_event(lv, "remote-flash", %{targets: targets})
      assert targets == ["#glance-diaper .glance-card", "#entries-#{entry.id}"]
    end

    test "a deleted entry pulses only its card", %{conn: conn, scope: scope, child: child} do
      entry = entry_fixture(scope, child, type: :feeding)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      {:ok, _} = Log.delete_entry(scope, entry)

      assert_push_event(lv, "remote-flash", %{targets: ["#glance-feed .glance-card"]})
    end

    test "the caregiver's own tap doesn't pulse", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      lv |> element(~s(button[phx-value-kind="diaper_pee"])) |> render_click()

      assert render(lv) =~ "Pee diaper"
      refute_push_event(lv, "remote-flash", _)
    end
  end

  describe "vitamin D drop" do
    import Trygg.LogFixtures

    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      child = child_fixture(scope)
      {:ok, child} = Families.update_child(scope, child, %{vitamin_d_reminder: true})
      %{conn: conn, scope: scope, child: child}
    end

    defp open_bottle_sheet(lv) do
      lv |> element("button", "Log a bottle") |> render_click()
      lv |> element(~s(button[phx-value-by="60"])) |> render_click()
    end

    test "can be logged with a bottle and shows on the feed", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      open_bottle_sheet(lv)

      assert has_element?(lv, "#vitamin-d-field")

      lv |> form("#bottle-form", entry: %{vitamin_d: "true"}) |> render_submit()

      assert [%{data: %{"vitamin_d" => true}}] = Log.list_entries(scope, child)
      assert has_element?(lv, "[data-vitamin-d]")
    end

    test "a bottle without the tick doesn't record it", %{conn: conn, scope: scope, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      open_bottle_sheet(lv)
      lv |> form("#bottle-form") |> render_submit()

      assert [%{data: data}] = Log.list_entries(scope, child)
      refute Map.has_key?(data, "vitamin_d")
      refute has_element?(lv, "[data-vitamin-d]")
    end

    test "the option disappears once today's drop is logged", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      open_bottle_sheet(lv)
      lv |> form("#bottle-form", entry: %{vitamin_d: "true"}) |> render_submit()

      lv |> element("button", "Log a bottle") |> render_click()
      refute has_element?(lv, "#vitamin-d-field")
    end

    test "is hidden when the reminder is off", %{conn: conn, scope: scope, child: child} do
      {:ok, child} = Families.update_child(scope, child, %{vitamin_d_reminder: false})
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      open_bottle_sheet(lv)

      refute has_element?(lv, "#vitamin-d-field")
    end

    test "can be added to an already logged bottle", %{conn: conn, scope: scope, child: child} do
      entry = entry_fixture(scope, child, %{:type => :feeding})

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      lv |> element(~s([id$="#{entry.id}"])) |> render_click()
      assert has_element?(lv, "#edit-vitamin-d")

      lv |> form("#edit-entry-form", entry: %{vitamin_d: "true"}) |> render_submit()

      assert %{data: %{"vitamin_d" => true}} = Log.get_entry!(scope, entry.id)
      assert has_element?(lv, "[data-vitamin-d]")
    end

    test "isn't offered on other bottles once today's drop is logged", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      entry_fixture(scope, child, %{
        :type => :feeding,
        "data" => %{"amount_ml" => 90, "vitamin_d" => true}
      })

      other = entry_fixture(scope, child, %{:type => :feeding})

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      lv |> element(~s([id$="#{other.id}"])) |> render_click()

      assert has_element?(lv, "#edit-entry-form")
      refute has_element?(lv, "#edit-vitamin-d")
    end

    test "isn't offered when the reminder is off", %{conn: conn, scope: scope, child: child} do
      {:ok, child} = Families.update_child(scope, child, %{vitamin_d_reminder: false})
      entry = entry_fixture(scope, child, %{:type => :feeding})

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      lv |> element(~s([id$="#{entry.id}"])) |> render_click()

      refute has_element?(lv, "#edit-vitamin-d")
    end

    test "can be unticked from the edit sheet", %{conn: conn, scope: scope, child: child} do
      entry =
        entry_fixture(scope, child, %{
          :type => :feeding,
          "data" => %{"amount_ml" => 90, "vitamin_d" => true}
        })

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      lv |> element(~s([id$="#{entry.id}"])) |> render_click()
      assert has_element?(lv, "#edit-vitamin-d")

      lv |> form("#edit-entry-form", entry: %{vitamin_d: "false"}) |> render_submit()

      assert %{data: data} = Log.get_entry!(scope, entry.id)
      refute Map.has_key?(data, "vitamin_d")
      assert data["amount_ml"] == 90.0
    end
  end

  describe "pull to refresh" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: child_fixture(scope)}
    end

    test "the refresh gesture re-syncs entries the socket didn't hear about", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      # Land an entry (this broadcasts, so the socket shows it), then remove it
      # straight from the repo so no broadcast tells the LiveView it's gone.
      entry = Trygg.LogFixtures.entry_fixture(scope, child, type: :diaper)
      assert render(lv) =~ "Pee diaper"
      Trygg.Repo.delete!(entry)
      assert render(lv) =~ "Pee diaper"

      # The pull-to-refresh gesture pushes "refresh"; the stream is rebuilt.
      html = render_hook(lv, "refresh", %{})
      refute html =~ "Pee diaper"
    end
  end

  describe "units" do
    setup %{conn: conn} do
      %{conn: conn, user: user, scope: scope} = register_and_log_in_user(%{conn: conn})
      {:ok, user} = Trygg.Accounts.update_user_settings(user, %{unit_system: :imperial})
      %{conn: conn, scope: Trygg.Accounts.Scope.for_user(user), child: child_fixture(scope)}
    end

    test "imperial viewer sees ounces while storage stays millilitres", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, _} =
        Log.create_entry(scope, child, :feeding, %{
          "data" => %{"amount_ml" => 90, "bottle_contents" => "formula"}
        })

      {:ok, _lv, html} = live_loaded(conn, ~p"/c/#{child}")
      assert html =~ "oz"
      refute html =~ "90 ml"

      assert [%{data: %{"amount_ml" => 90.0}}] = Log.list_entries(scope, child)
    end

    test "reset zeros a fractional ounce amount in the bottle sheet", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      # 74 ml displays as 2.5 oz. Reset used to trunc(-amount), leaving 0.5.
      Trygg.LogFixtures.entry_fixture(scope, child, %{
        :type => :feeding,
        "data" => %{"bottle_contents" => "formula", "amount_ml" => 74}
      })

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      lv |> element("button", "Log a bottle") |> render_click()

      assert has_element?(lv, "input#bottle-amount[value='2.5']")

      lv |> element("#bottle-reset") |> render_click()

      assert has_element?(lv, "input#bottle-amount[value='0']")
      refute has_element?(lv, "input#bottle-amount[value='0.5']")
    end
  end

  describe "configurable layout" do
    import Trygg.LogFixtures

    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      child = child_fixture(scope, %{timezone: "Etc/UTC"})
      %{conn: conn, scope: scope, child: child}
    end

    test "everything shows by default", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      for id <- ~w(glance-feed glance-diaper glance-sleep log-sleep log-bottle log-diaper) do
        assert has_element?(lv, "##{id}"), id
      end
    end

    test "a bottles-only child gets bottle cards and buttons only", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, child} = Families.update_child(scope, child, %{tracked_types: [:feeding]})
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      assert has_element?(lv, "#glance-feed")
      assert has_element?(lv, "#log-bottle")
      refute has_element?(lv, "#glance-diaper")
      refute has_element?(lv, "#glance-sleep")
      refute has_element?(lv, "#log-sleep")
      refute has_element?(lv, "#log-diaper")

      lv |> element("button[phx-value-kind='earlier']") |> render_click()
      assert has_element?(lv, "#quick-sheet button[phx-value-kind='bottle']")
      refute has_element?(lv, "#quick-sheet button[phx-value-kind='sleep_past']")
      refute has_element?(lv, "#quick-sheet button[phx-value-kind='diaper_past']")
    end

    test "recent entries of untracked types are left out", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      feed = entry_fixture(scope, child, %{:type => :feeding})
      diaper = entry_fixture(scope, child, %{:type => :diaper})
      {:ok, child} = Families.update_child(scope, child, %{tracked_types: [:feeding]})

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      assert has_element?(lv, "#entries-#{feed.id}")
      refute has_element?(lv, "#entries-#{diaper.id}")
    end

    test "diaper alerts are dropped when diapers aren't tracked", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      now = DateTime.utc_now()

      entry_fixture(scope, child, %{
        :type => :diaper,
        "started_at" => DateTime.add(now, -7 * 3600, :second)
      })

      entry_fixture(scope, child, %{
        :type => :feeding,
        "started_at" => DateTime.add(now, -30 * 60, :second)
      })

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      assert has_element?(lv, "#home-alerts-no-wet-diaper")

      {:ok, child} = Families.update_child(scope, child, %{tracked_types: [:feeding]})
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      refute has_element?(lv, "#home-alerts-no-wet-diaper")
    end

    test "a caregiver can customize Home and the owner sees it live", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      member = user_fixture()
      membership_fixture(child, member, :caregiver)

      {:ok, owner_lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      assert has_element?(owner_lv, "#glance-sleep")

      member_conn = log_in_user(Phoenix.ConnTest.build_conn(), member)
      {:ok, lv, _html} = live_loaded(member_conn, ~p"/c/#{child}")

      lv |> element("#customize-home") |> render_click()
      assert has_element?(lv, "#layout-form #layout-sleep[checked]")

      lv
      |> form("#layout-form", layout: %{tracked_types: ["", "feeding", "diaper"]})
      |> render_submit()

      refute has_element?(lv, "#quick-sheet")
      refute has_element?(lv, "#glance-sleep")
      assert Families.get_child!(scope, child.id).tracked_types == [:feeding, :diaper]

      refute has_element?(owner_lv, "#glance-sleep")
    end

    test "customizing can't leave nothing tracked", %{conn: conn, scope: scope, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      lv |> element("#customize-home") |> render_click()
      lv |> form("#layout-form", layout: %{tracked_types: [""]}) |> render_submit()

      assert has_element?(lv, "#layout-error")
      assert Families.get_child!(scope, child.id).tracked_types == [:feeding, :diaper, :sleep]
    end

    test "viewers can't customize Home" do
      %{child: child, member: member} = shared_child_fixture(:viewer)
      conn = log_in_user(build_conn(), member)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      refute has_element?(lv, "#customize-home")
    end

    test "the layout changes live when an owner edits it elsewhere", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      assert has_element?(lv, "#glance-sleep")

      {:ok, _} = Families.update_child(scope, child, %{tracked_types: [:feeding, :diaper]})

      refute has_element?(lv, "#glance-sleep")
      assert has_element?(lv, "#glance-diaper")
    end
  end

  describe "realtime child rename" do
    setup :register_and_log_in_user

    test "the title updates when another caregiver renames the child", %{conn: conn, scope: scope} do
      child = child_fixture(scope)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      {:ok, _} = Families.update_child(scope, child, %{name: "Wobble"})
      assert render(lv) =~ "Wobble"
    end
  end

  describe "realtime children list" do
    setup :register_and_log_in_user

    test "a child added from another session appears without a reload", %{
      conn: conn,
      scope: scope
    } do
      child = child_fixture(scope)
      {:ok, lv, html} = live_loaded(conn, ~p"/c/#{child}")
      refute html =~ "Sibling"

      {:ok, _} = Families.create_child(scope, %{name: "Sibling", timezone: "Etc/UTC"})

      assert render(lv) =~ "Sibling"
    end

    test "a rename by another caregiver updates the switcher", %{conn: conn, scope: scope} do
      child = child_fixture(scope)
      _other = child_fixture(scope, %{name: "Keeper"})
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      {:ok, _} = Families.update_child(scope, child, %{name: "Renamed"})

      assert render(lv) =~ "Renamed"
      refute render(lv) =~ child.name
    end
  end

  describe "realtime access changes" do
    test "a caregiver is bounced home the moment their access is revoked", %{conn: conn} do
      owner_scope = user_scope_fixture()
      child = child_fixture(owner_scope)

      caregiver = user_fixture()
      membership = membership_fixture(child, caregiver, :caregiver)
      conn = log_in_user(conn, caregiver)

      {:ok, lv, html} = live_loaded(conn, ~p"/c/#{child}")
      assert html =~ "Start sleep"

      {:ok, _} = Families.remove_member(owner_scope, child, membership)

      assert_redirect(lv, ~p"/")
    end

    test "losing write access hides the logging controls live", %{conn: conn} do
      owner_scope = user_scope_fixture()
      child = child_fixture(owner_scope)

      caregiver = user_fixture()
      membership = membership_fixture(child, caregiver, :caregiver)
      conn = log_in_user(conn, caregiver)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      assert render(lv) =~ "Start sleep"

      {:ok, _} = Families.update_member_role(owner_scope, child, membership, :viewer)

      refute render(lv) =~ "Start sleep"
    end

    test "a child deleted elsewhere bounces open dashboards home", %{conn: conn} do
      owner_scope = user_scope_fixture()
      child = child_fixture(owner_scope)

      caregiver = user_fixture()
      membership_fixture(child, caregiver, :caregiver)
      conn = log_in_user(conn, caregiver)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      {:ok, _} = Families.delete_child(owner_scope, child)

      assert_redirect(lv, ~p"/")
    end
  end

  describe "outlook" do
    import Trygg.LogFixtures

    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      child = child_fixture(scope, %{timezone: "Etc/UTC"})
      %{conn: conn, scope: scope, child: child}
    end

    test "a quiet log shows plain glance cards and no alerts", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      assert has_element?(lv, "#glance-feed", "No feeds yet")
      assert has_element?(lv, "#glance-feed", "none today")
      assert has_element?(lv, "#glance-diaper")
      assert has_element?(lv, "#glance-diaper", "none today")
      assert has_element?(lv, "#glance-sleep")
      refute has_element?(lv, "#home-alerts")

      # The big friendly Home cards, one per category, in their resting tone.
      assert has_element?(lv, "#glance-feed .glance-card.glance-feed[data-tone='base']")
      assert has_element?(lv, "#glance-diaper .glance-card.glance-diaper[data-tone='base']")
      assert has_element?(lv, "#glance-sleep .glance-card.glance-sleep[data-tone='base']")
      refute has_element?(lv, "#glance-sleep .glance-snooze")
    end

    test "today's totals show inside the glance cards, not a separate row", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      entry_fixture(scope, child, %{"data" => %{"amount_ml" => 90}, :type => :feeding})
      entry_fixture(scope, child, %{"data" => %{"kind" => "pee"}, :type => :diaper})
      entry_fixture(scope, child, %{"data" => %{"kind" => "poo"}, :type => :diaper})

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      assert has_element?(lv, "#glance-feed", "1 feed · 90 ml today")
      assert has_element?(lv, "#glance-diaper", "2 diapers")
      assert has_element?(lv, "#glance-diaper", "💧 1")
      assert has_element?(lv, "#glance-diaper", "💩 1")
      assert has_element?(lv, "#glance-sleep", "slept today")
    end

    test "regular bottles produce a next-feed estimate on the feed card", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      feed_days(scope, child, 3, every_hours: 3, last_hours_ago: 1)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      assert has_element?(lv, "#glance-feed", "Next ~")
      refute has_element?(lv, "#glance-feed", "later than usual")
    end

    test "a feed well past its usual time is framed against their rhythm, not a schedule", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      feed_days(scope, child, 3, every_hours: 3, last_hours_ago: 5)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      assert has_element?(lv, "#glance-feed", "later than usual")
      refute has_element?(lv, "#glance-feed", "overdue")
    end

    test "six dry hours with recent activity raises a hydration alert", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      entry_fixture(scope, child, %{
        :type => :diaper,
        "started_at" => DateTime.add(now, -7 * 3600, :second)
      })

      entry_fixture(scope, child, %{
        :type => :feeding,
        "started_at" => DateTime.add(now, -30 * 60, :second)
      })

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      assert has_element?(lv, "#home-alerts")
      assert has_element?(lv, "#home-alerts-no-wet-diaper", "No wet diaper")
      assert has_element?(lv, "#glance-diaper", "no wet diaper")
      assert has_element?(lv, "#home-alerts", "Not medical advice")
    end

    test "an alert can be dismissed", %{conn: conn, scope: scope, child: child} do
      now = DateTime.utc_now()

      entry_fixture(scope, child, %{
        :type => :diaper,
        "started_at" => DateTime.add(now, -7 * 3600, :second)
      })

      entry_fixture(scope, child, %{
        :type => :feeding,
        "started_at" => DateTime.add(now, -30 * 60, :second)
      })

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      assert has_element?(lv, "#home-alerts-no-wet-diaper")

      lv |> element("#home-alerts-no-wet-diaper-dismiss") |> render_click()

      # Only this alert is dismissed. Other time-of-day dependent alerts (e.g.
      # "low wet diapers today" shortly after midnight) may legitimately remain,
      # so don't assert the whole alerts box is gone.
      refute has_element?(lv, "#home-alerts-no-wet-diaper")
      refute has_element?(lv, "#home-alerts-no-wet-diaper-dismiss")
    end

    test "a known age gives a next-nap estimate from the age prior", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      # Pin the child's local clock to around midday so "woke 20 minutes ago"
      # is unambiguously this morning's wake-up whatever the wall clock says.
      {:ok, child} =
        Families.update_child(scope, child, %{
          birth_date: Date.add(Date.utc_today(), -60),
          timezone: midday_timezone()
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      entry_fixture(scope, child, %{
        :type => :sleep,
        "started_at" => DateTime.add(now, -9 * 3600, :second),
        "ended_at" => DateTime.add(now, -20 * 60, :second)
      })

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      assert has_element?(lv, "#glance-sleep", "Nap ·")
    end

    # The rhythm dial is commented out of the Home screen for now (see
    # TryggWeb.DashboardLive's render/1) — re-enable these once it's back.
    @tag :skip
    test "the rhythm dial calls out the next nap while the child is awake", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, child} =
        Families.update_child(scope, child, %{
          birth_date: Date.add(Date.utc_today(), -60),
          timezone: midday_timezone()
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      entry_fixture(scope, child, %{
        :type => :sleep,
        "started_at" => DateTime.add(now, -9 * 3600, :second),
        "ended_at" => DateTime.add(now, -20 * 60, :second)
      })

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      assert has_element?(lv, "#rhythm-dial", "Next nap")
    end

    @tag :skip
    test "the rhythm dial shows the running sleep in its centre", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      Trygg.Log.start_timer(scope, child, :sleep)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      assert has_element?(lv, "#rhythm-dial", "Asleep")
      assert has_element?(lv, "#rhythm-dial-elapsed")
    end
  end

  describe "weight-check reminder" do
    import Trygg.GrowthFixtures

    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      # 400 days old -> a 90-day check interval applies.
      child =
        child_fixture(scope, %{timezone: "Etc/UTC", birth_date: Date.add(Date.utc_today(), -400)})

      %{conn: conn, scope: scope, child: child}
    end

    test "banners when the last weight is stale", %{conn: conn, scope: scope, child: child} do
      measurement_fixture(scope, child, %{"measured_on" => Date.add(Date.utc_today(), -120)})

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      assert has_element?(lv, "#weight-check-reminder", "Time for a weight check")
      assert has_element?(lv, "#weight-check-reminder a", "Log it in Vitals")
    end

    test "the banner can be dismissed", %{conn: conn, scope: scope, child: child} do
      measurement_fixture(scope, child, %{"measured_on" => Date.add(Date.utc_today(), -120)})

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      lv |> element("#weight-check-reminder-dismiss") |> render_click()

      refute has_element?(lv, "#weight-check-reminder")
    end

    test "a dismissed banner stays hidden after a reload", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      measurement_fixture(scope, child, %{"measured_on" => Date.add(Date.utc_today(), -120)})

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      lv |> element("#weight-check-reminder-dismiss") |> render_click()

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      refute has_element?(lv, "#weight-check-reminder")
    end

    test "no banner when a recent weight is on file", %{conn: conn, scope: scope, child: child} do
      measurement_fixture(scope, child, %{"measured_on" => Date.utc_today()})

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      refute has_element?(lv, "#weight-check-reminder")
    end

    test "banners when no weight has ever been logged", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      assert has_element?(lv, "#weight-check-reminder", "No weight logged yet")
    end

    test "respects a shorter custom cadence", %{conn: conn, scope: scope, child: child} do
      measurement_fixture(scope, child, %{"measured_on" => Date.add(Date.utc_today(), -20)})

      # 20 days stale is under the 90-day CDC interval — no banner yet.
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      refute has_element?(lv, "#weight-check-reminder")

      {:ok, _} = Trygg.Accounts.update_user_settings(scope.user, %{"weight_reminder_days" => 7})

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      assert has_element?(lv, "#weight-check-reminder", "You asked to be reminded every 7 days")
    end

    test "no banner when the caregiver turned reminders off", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      measurement_fixture(scope, child, %{"measured_on" => Date.add(Date.utc_today(), -300)})
      {:ok, _} = Trygg.Accounts.update_user_settings(scope.user, %{"weight_reminder_days" => 0})

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      refute has_element?(lv, "#weight-check-reminder")
    end
  end

  describe "photos" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: child_fixture(scope)}
    end

    test "a photo attached in the bottle sheet shows in the feed", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      lv |> element("button", "Log a bottle") |> render_click()

      photo =
        file_input(lv, "#bottle-form", :photo, [
          %{name: "baby.png", content: Trygg.LogFixtures.tiny_png(), type: "image/png"}
        ])

      assert render_upload(photo, "baby.png")

      lv |> form("#bottle-form", entry: %{bottle_contents: "formula"}) |> render_submit()

      assert [%{type: :feeding} = feed] = Log.list_entries(scope, child)
      assert feed.photo_key
      assert feed.photo_content_type == "image/png"

      src = ~p"/c/#{child}/log/#{feed.id}/photo"
      assert render(lv) =~ src

      resp = get(conn, src)
      assert resp.status == 200
      assert resp.resp_body == Trygg.LogFixtures.tiny_png()
    end

    test "a photo can be added to an existing entry from the edit modal", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      entry = Trygg.LogFixtures.entry_fixture(scope, child, type: :diaper)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      lv |> element(~s([id$="#{entry.id}"])) |> render_click()

      photo =
        file_input(lv, "#edit-entry-form", :photo, [
          %{name: "d.png", content: Trygg.LogFixtures.tiny_png(), type: "image/png"}
        ])

      render_upload(photo, "d.png")
      lv |> form("#edit-entry-form", entry: %{}) |> render_submit()

      updated = Log.get_entry!(scope, entry.id)
      assert updated.photo_key
      assert render(lv) =~ ~p"/c/#{child}/log/#{entry.id}/photo"
    end

    test "the remove-photo toggle clears an entry's photo", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, attrs} = Log.store_photo(child, Trygg.LogFixtures.tiny_png(), "image/png")

      {:ok, entry} =
        Log.create_entry(scope, child, :diaper, Map.merge(%{"data" => %{"kind" => "pee"}}, attrs))

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      lv |> element(~s([id$="#{entry.id}"])) |> render_click()

      lv
      |> form("#edit-entry-form", entry: %{remove_photo: "true"})
      |> render_submit()

      refute Log.get_entry!(scope, entry.id).photo_key
      assert {:error, _} = Trygg.Storage.get(attrs["photo_key"])
    end
  end

  describe "push notification prompt" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: child_fixture(scope)}
    end

    test "renders the one-time opt-in nudge, hidden and wired to the hook + VAPID key",
         %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      assert has_element?(lv, "#push-prompt[phx-hook='PushPrompt'][hidden]")

      html = lv |> element("#push-prompt") |> render()
      assert html =~ "data-vapid-key=\"#{Trygg.Push.vapid_public_key()}\""

      assert has_element?(lv, "#push-prompt [data-push-prompt-action='enable']", "Turn on")
      assert has_element?(lv, "#push-prompt [data-push-prompt-action='dismiss']")
    end
  end
end
