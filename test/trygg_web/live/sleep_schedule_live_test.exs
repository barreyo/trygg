defmodule TryggWeb.SleepScheduleLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.Families
  alias Trygg.Sleep.DaySchedules

  defp child_of_age(scope, days),
    do: child_fixture(scope, %{birth_date: Date.add(Date.utc_today(), -days)})

  describe "auth and navigation" do
    test "anonymous users are sent to log in", %{conn: conn} do
      child = child_fixture()

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(conn, ~p"/c/#{child}/sleep/schedule")
    end

    test "a non-member is bounced", %{conn: conn} do
      child = child_fixture()
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => _}}}} =
               live(conn, ~p"/c/#{child}/sleep/schedule")
    end

    test "when sleep isn't tracked it sends you to Today", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      {:ok, child} = Families.update_tracked_types(scope, child_fixture(scope), [:diaper])

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/c/#{child}/sleep/schedule")
      assert to == ~p"/c/#{child}"
    end

    test "the Sleep tab links to it", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      child = child_of_age(scope, 100)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")
      assert has_element?(lv, "#sleep-schedule-edit[href='#{~p"/c/#{child}/sleep/schedule"}']")
    end
  end

  describe "a newborn" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: child_fixture(scope)}
    end

    test "gets a soft rhythm with anchors and no naps", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/schedule")

      assert has_element?(lv, "#schedule-anchors")
      assert has_element?(lv, "#schedule-wake-window")
      refute has_element?(lv, "#schedule-items")
      refute has_element?(lv, "#schedule-slots")
      assert has_element?(lv, "#schedule-input-wake")
    end

    test "saves a wake-up and evening anchor", %{conn: conn, scope: scope, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/schedule")

      lv
      |> form("#schedule-form", schedule: %{wake: "06:30", bedtime: "21:00"})
      |> render_submit()

      assert %{wake_minutes: 390, bedtime_minutes: 1260} = DaySchedules.get(scope, child)
      assert has_element?(lv, "#schedule-evening-row", "21:00")
      assert has_element?(lv, "#schedule-reset")
    end
  end

  describe "from 13 weeks" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: child_of_age(scope, 100)}
    end

    test "lists the guide's naps and bedtime", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/schedule")

      assert has_element?(lv, "#schedule-items #schedule-nap-1")
      assert has_element?(lv, "#schedule-items #schedule-nap-4")
      assert has_element?(lv, "#schedule-items #schedule-bed-bed")
      assert has_element?(lv, "#schedule-guide-label", "the guide")
      refute has_element?(lv, "#schedule-reset")
    end

    test "changing the nap count adds or drops rows without saving", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/schedule")
      assert has_element?(lv, "#schedule-slot-3")

      lv |> form("#schedule-form", schedule: %{naps: "2"}) |> render_change()
      assert has_element?(lv, "#schedule-slot-1")
      refute has_element?(lv, "#schedule-slot-2")
      assert DaySchedules.get(scope, child) == nil
    end

    test "saves choices and the day follows them", %{conn: conn, scope: scope, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/schedule")

      lv
      |> form("#schedule-form",
        schedule: %{
          wake: "06:00",
          bedtime: "19:00",
          naps: "3",
          windows: %{"0" => "80"},
          lengths: %{"2" => "45"}
        }
      )
      |> render_submit()

      assert %{
               wake_minutes: 360,
               bedtime_minutes: 1140,
               nap_count: 3,
               wake_windows: [80],
               nap_lengths: [nil, nil, 45]
             } = DaySchedules.get(scope, child)

      assert has_element?(lv, "#schedule-nap-3")
      refute has_element?(lv, "#schedule-nap-4")
      assert has_element?(lv, "#schedule-bed-bed", "yours")
      assert has_element?(lv, "#schedule-guide-label", "your changes")
    end

    test "back to the guide drops the choices", %{conn: conn, scope: scope, child: child} do
      {:ok, _} = DaySchedules.save(scope, child, %{nap_count: 3})
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/schedule")
      assert has_element?(lv, "#schedule-reset")

      lv |> element("#schedule-reset") |> render_click()

      assert DaySchedules.get(scope, child) == nil
      assert has_element?(lv, "#schedule-nap-4")
      refute has_element?(lv, "#schedule-reset")
    end

    test "says when the guide has moved on, and keeps their settings on request", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, _} = DaySchedules.save(scope, child, %{wake_minutes: 400})
      Trygg.Repo.update_all(Trygg.Sleep.DaySchedule, set: [guide_id: "newborn"])

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/schedule")
      assert has_element?(lv, "#schedule-stale")

      lv |> element("#schedule-keep") |> render_click()
      refute has_element?(lv, "#schedule-stale")
    end

    test "a change made elsewhere shows up live", %{conn: conn, scope: scope, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/schedule")
      assert has_element?(lv, "#schedule-nap-3")

      {:ok, _} = DaySchedules.save(scope, child, %{nap_count: 2})
      _ = render(lv)

      refute has_element?(lv, "#schedule-nap-3")
    end
  end

  describe "viewers" do
    test "see the day but not the form", %{conn: conn} do
      %{owner_scope: owner, child: child, member: member} = shared_child_fixture(:viewer)
      {:ok, _} = DaySchedules.save(owner, child, %{nap_count: 3})
      conn = log_in_user(conn, member)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/schedule")
      assert has_element?(lv, "#schedule-day")
      assert has_element?(lv, "#schedule-read-only")
      refute has_element?(lv, "#schedule-form")
    end
  end
end
