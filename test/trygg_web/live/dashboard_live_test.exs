defmodule TryggWeb.DashboardLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.{Families, Log}

  describe "auth boundary" do
    test "GET / redirects anonymous users to log in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/")
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
      assert {:error, {:live_redirect, %{to: "/children/new"}}} = live(conn, ~p"/")
    end

    test "/ opens the first child for a user who has one", %{conn: conn, scope: scope} do
      child = child_fixture(scope)
      assert {:error, {:live_redirect, %{to: path}}} = live(conn, ~p"/")
      assert path == ~p"/c/#{child}"
    end
  end

  describe "logging" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: child_fixture(scope)}
    end

    test "a one-tap diaper button records an entry", %{conn: conn, scope: scope, child: child} do
      {:ok, lv, _html} = live(conn, ~p"/c/#{child}")

      lv |> element(~s(button[phx-value-kind="diaper_pee"])) |> render_click()

      assert render(lv) =~ "Pee diaper"
      assert [%{type: :diaper}] = Log.list_entries(scope, child)
    end

    test "a past diaper can be logged through the sheet", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live(conn, ~p"/c/#{child}")

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

    test "a future diaper time is rejected", %{conn: conn, scope: scope, child: child} do
      {:ok, lv, _html} = live(conn, ~p"/c/#{child}")

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
      {:ok, lv, _html} = live(conn, ~p"/c/#{child}")

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

    test "a bottle can be back-dated through the sheet", %{conn: conn, scope: scope, child: child} do
      {:ok, lv, _html} = live(conn, ~p"/c/#{child}")

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
      {:ok, lv, _html} = live(conn, ~p"/c/#{child}")

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

      {:ok, lv, _html} = live(conn, ~p"/c/#{child}")

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
      {:ok, lv, _html} = live(conn, ~p"/c/#{child}")

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
      {:ok, lv, _html} = live(conn, ~p"/c/#{child}")
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
      {:ok, lv, _html} = live(conn, ~p"/c/#{child}")
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
      {:ok, lv, _html} = live(conn, ~p"/c/#{child}")
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
      {:ok, lv, _html} = live(conn, ~p"/c/#{child}")

      now = DateTime.utc_now()
      started = now |> DateTime.add(-90, :minute) |> Calendar.strftime("%Y-%m-%dT%H:%M")
      ended = now |> DateTime.add(-15, :minute) |> Calendar.strftime("%Y-%m-%dT%H:%M")

      lv |> element("button", "Add a sleep from earlier") |> render_click()

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

    test "a past sleep with the end before the start is rejected", %{conn: conn, child: child} do
      {:ok, lv, _html} = live(conn, ~p"/c/#{child}")

      now = DateTime.utc_now()
      started = now |> Calendar.strftime("%Y-%m-%dT%H:%M")
      ended = now |> DateTime.add(-30, :minute) |> Calendar.strftime("%Y-%m-%dT%H:%M")

      lv |> element("button", "Add a sleep from earlier") |> render_click()

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
      {:ok, lv_a, _html} = live(conn, ~p"/c/#{child}")
      lv_a |> element("button", "Start sleep") |> render_click()

      # caregiver B opens the dashboard fresh (as if returning after closing the app)
      other = user_fixture()
      membership_fixture(child, other, :caregiver)
      conn_b = log_in_user(Phoenix.ConnTest.build_conn(), other)

      {:ok, _lv_b, html_b} = live(conn_b, ~p"/c/#{child}")
      assert html_b =~ "Asleep"
      assert html_b =~ ~s(phx-hook="Timer")

      # and it's the same server-side timer, not a new one
      assert [%{type: :sleep, ended_at: nil}] = Log.running_timers(scope, child)
    end

    test "an entry logged by another caregiver appears live", %{conn: conn, child: child} do
      {:ok, lv, _html} = live(conn, ~p"/c/#{child}")

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

      {:ok, _lv, html} = live(conn, ~p"/c/#{child}")
      assert html =~ "oz"
      refute html =~ "90 ml"

      assert [%{data: %{"amount_ml" => 90.0}}] = Log.list_entries(scope, child)
    end
  end

  describe "realtime child rename" do
    setup :register_and_log_in_user

    test "the title updates when another caregiver renames the child", %{conn: conn, scope: scope} do
      child = child_fixture(scope)
      {:ok, lv, _html} = live(conn, ~p"/c/#{child}")

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
      {:ok, lv, html} = live(conn, ~p"/c/#{child}")
      refute html =~ "Sibling"

      {:ok, _} = Families.create_child(scope, %{name: "Sibling", timezone: "Etc/UTC"})

      assert render(lv) =~ "Sibling"
    end

    test "a rename by another caregiver updates the switcher", %{conn: conn, scope: scope} do
      child = child_fixture(scope)
      _other = child_fixture(scope, %{name: "Keeper"})
      {:ok, lv, _html} = live(conn, ~p"/c/#{child}")

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

      {:ok, lv, html} = live(conn, ~p"/c/#{child}")
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

      {:ok, lv, _html} = live(conn, ~p"/c/#{child}")
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

      {:ok, lv, _html} = live(conn, ~p"/c/#{child}")

      {:ok, _} = Families.delete_child(owner_scope, child)

      assert_redirect(lv, ~p"/")
    end
  end
end
