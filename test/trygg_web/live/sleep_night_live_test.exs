defmodule TryggWeb.SleepNightLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.Families
  alias Trygg.Sleep.NightWakes

  defp older_child(scope),
    do: child_fixture(scope, %{birth_date: Date.add(Date.utc_today(), -100)})

  describe "auth and navigation" do
    test "anonymous users are sent to log in", %{conn: conn} do
      child = child_fixture()

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(conn, ~p"/c/#{child}/sleep/night")
    end

    test "when sleep isn't tracked it sends you to Today", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      child = child_fixture(scope)
      {:ok, child} = Families.update_tracked_types(scope, child, [:diaper])
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/c/#{child}/sleep/night")
      assert to == ~p"/c/#{child}"
    end

    test "is reachable from the Sleep pages", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      child = child_fixture(scope)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")
      assert has_element?(lv, "#subnav-night[href='#{~p"/c/#{child}/sleep/night"}']")

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")
      assert has_element?(lv, "#subnav-night[aria-current=page]")
    end
  end

  describe "a newborn (C.R.I.E.S.)" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: child_fixture(scope)}
    end

    test "offers C.R.I.E.S. and works through its five steps without timers", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")
      assert has_element?(lv, "#night-start", "C.R.I.E.S.")

      assert lv |> element("#night-steps-preview") |> render() |> String.split("<li") |> length() ==
               6

      lv |> element("#night-start") |> render_click()
      assert has_element?(lv, "#night-step-letter", "C")
      assert has_element?(lv, "#night-step-name", "Contain")
      refute has_element?(lv, "#night-countdown")
      assert %{method: :cries} = NightWakes.active(scope, child)

      for letter <- ~w(R I E S) do
        lv |> element("#night-next") |> render_click()
        assert has_element?(lv, "#night-step-letter", letter)
      end

      refute has_element?(lv, "#night-next")
      refute has_element?(lv, "#night-fed")
    end

    test "settling ends it and says where", %{conn: conn, scope: scope, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")
      lv |> element("#night-start") |> render_click()
      lv |> element("#night-next") |> render_click()
      lv |> element("#night-settled") |> render_click()

      assert has_element?(lv, "#night-idle")
      assert has_element?(lv, "#night-last", "Settled at step 2 (R)")
      assert NightWakes.active(scope, child) == nil
      assert has_element?(lv, "#night-recent", "1 waking: 1 settled")
    end
  end

  describe "from 13 weeks (S.I.T. B.A.C.K.)" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: older_child(scope)}
    end

    test "starts with a five-minute countdown that the server anchors", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")
      assert has_element?(lv, "#night-start", "S.I.T. B.A.C.K.")

      lv |> element("#night-start") |> render_click()
      assert has_element?(lv, "#night-step-letter", "S")
      assert has_element?(lv, "#night-step-name", "Stop, wait, watch")

      wake = NightWakes.active(scope, child)
      ends = DateTime.to_unix(wake.step_started_at) * 1000 + 300_000
      assert has_element?(lv, ~s(#night-countdown[phx-hook=NightTimer][data-ends-at="#{ends}"]))
      assert has_element?(lv, "#night-countdown", "5:00")
      assert has_element?(lv, "#night-countdown", "Up to 8 minutes")
    end

    test "next moves through the steps with two-minute countdowns", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")
      lv |> element("#night-start") |> render_click()
      lv |> element("#night-next") |> render_click()

      assert has_element?(lv, "#night-step-letter", "I")
      assert has_element?(lv, "#night-countdown", "2:00")
      assert has_element?(lv, "#night-progress li[aria-current=step]", "I")
    end

    test "the last step offers a feed or starting over, and shows the feed hint", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")
      lv |> element("#night-start") |> render_click()
      for _ <- 1..6, do: lv |> element("#night-next") |> render_click()

      assert has_element?(lv, "#night-step-letter", "K")
      refute has_element?(lv, "#night-countdown")
      refute has_element?(lv, "#night-next")
      assert has_element?(lv, "#night-feed-hint")
      assert has_element?(lv, "#night-fed")

      lv |> element("#night-restart") |> render_click()
      assert has_element?(lv, "#night-step-letter", "S")
      assert %{step: 0} = NightWakes.active(scope, child)
    end

    test "Fed ends it as a feed", %{conn: conn, scope: scope, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")
      lv |> element("#night-start") |> render_click()
      for _ <- 1..6, do: lv |> element("#night-next") |> render_click()
      lv |> element("#night-fed") |> render_click()

      assert has_element?(lv, "#night-last", "Fed")
      assert [%{outcome: :fed, settled_step: 6}] = NightWakes.recent(scope, child)
    end

    test "stopping records no result", %{conn: conn, scope: scope, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")
      lv |> element("#night-start") |> render_click()
      lv |> element("#night-stop") |> render_click()

      assert [%{outcome: :stopped}] = NightWakes.recent(scope, child)
      assert has_element?(lv, "#night-start")
    end

    test "opening it mid-waking picks up the step in progress", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, wake} = NightWakes.start(scope, child, :sit_back)
      {:ok, _} = NightWakes.advance(scope, wake, 0)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")
      assert has_element?(lv, "#night-step-letter", "I")
      assert has_element?(lv, "#night-started-by")
    end
  end

  describe "handing over to a partner" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      child = older_child(scope)
      partner = user_fixture(%{first_name: "Sam"})
      membership_fixture(child, partner, :caregiver)
      %{conn: conn, scope: scope, child: child, partner: user_scope_fixture(partner)}
    end

    test "a waking the partner starts, advances and ends shows live", %{
      conn: conn,
      child: child,
      partner: partner
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")
      assert has_element?(lv, "#night-idle")

      {:ok, wake} = NightWakes.start(partner, child, :sit_back)
      assert has_element?(lv, "#night-step-letter", "S")
      assert has_element?(lv, "#night-started-by", "by Sam")

      {:ok, wake} = NightWakes.advance(partner, wake, 0)
      assert has_element?(lv, "#night-step-letter", "I")
      assert has_element?(lv, ~s(#night-step[data-step="1"]))

      {:ok, _} = NightWakes.finish(partner, wake, :settled)
      assert has_element?(lv, "#night-idle")
      assert has_element?(lv, "#night-last", "Settled at step 2")
    end

    test "either of us can take over mid-sequence", %{
      conn: conn,
      scope: scope,
      child: child,
      partner: partner
    } do
      {:ok, wake} = NightWakes.start(partner, child, :sit_back)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")

      lv |> element("#night-next") |> render_click()
      assert %{step: 1} = NightWakes.active(partner, child)

      lv |> element("#night-settled") |> render_click()
      assert NightWakes.active(scope, child) == nil
      assert %{outcome: :settled, started_by_id: id} = hd(NightWakes.recent(scope, child))
      assert id == wake.started_by_id
    end

    test "tapping next on a step that has already moved on doesn't skip one", %{
      conn: conn,
      child: child,
      partner: partner
    } do
      {:ok, wake} = NightWakes.start(partner, child, :sit_back)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")

      # The partner moves on first; this device still shows the old step for an instant.
      {:ok, _} = NightWakes.advance(partner, wake, 0)
      render_click(lv, "next", %{"step" => "0"})

      assert has_element?(lv, "#night-step-letter", "I")
      assert %{step: 1} = NightWakes.active(partner, child)
    end

    test "the Sleep tab shows a banner while a waking is in progress", %{
      conn: conn,
      child: child,
      partner: partner
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")
      refute has_element?(lv, "#night-wake-banner")

      {:ok, wake} = NightWakes.start(partner, child, :sit_back)
      assert has_element?(lv, "#night-wake-banner[href='#{~p"/c/#{child}/sleep/night"}']")

      {:ok, _} = NightWakes.finish(partner, wake, :settled)
      refute has_element?(lv, "#night-wake-banner")
    end
  end

  describe "viewers" do
    test "can watch a waking but not run one", %{conn: conn} do
      owner = user_scope_fixture()
      child = older_child(owner)
      %{conn: conn, scope: viewer} = register_and_log_in_user(%{conn: conn})
      membership_fixture(child, viewer.user, :viewer)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")
      refute has_element?(lv, "#night-start")
      assert has_element?(lv, "#night-idle", "only a caregiver")

      {:ok, wake} = NightWakes.start(owner, child, :sit_back)
      assert has_element?(lv, "#night-step-letter", "S")
      refute has_element?(lv, "#night-next")
      refute has_element?(lv, "#night-settled")

      render_click(lv, "finish", %{"outcome" => "settled"})
      assert NightWakes.active(owner, child).id == wake.id
    end
  end

  describe "the toolkit" do
    test "summarises the last two weeks of wakings", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      child = older_child(scope)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")
      assert has_element?(lv, "#night-wakes-empty")

      {:ok, wake} = NightWakes.start(scope, child, :sit_back)
      {:ok, wake} = NightWakes.advance(scope, wake, 0)
      {:ok, _} = NightWakes.finish(scope, wake, :settled)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/toolkit")
      assert has_element?(lv, "#night-wakes-summary", "1 in the last 2 weeks: 1 settled")
      assert has_element?(lv, "#night-wakes-steps", "step 2")
      assert has_element?(lv, "#open-night-mode[href='#{~p"/c/#{child}/sleep/night"}']")
    end
  end
end
