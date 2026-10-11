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

  describe "ABCs check-ins" do
    alias Trygg.Sleep.{Abcs, NightWake, Phase, Plans}

    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})

      child =
        child_fixture(scope, %{birth_date: Date.add(Date.utc_today(), -170), timezone: "Etc/UTC"})

      {:ok, child} =
        Families.update_sleep_toolkit(scope, child, %{sleep_training_cleared_on: Date.utc_today()})

      checks = Map.new(Abcs.preflight_ids(), &{&1, Date.to_iso8601(Date.utc_today())})
      {:ok, child} = Families.update_sleep_toolkit(scope, child, %{sleep_checks: checks})

      %{conn: conn, scope: scope, child: child}
    end

    # A plan whose current night is `night` right now.
    defp start_plan(scope, child, night, attrs \\ %{}) do
      local = DateTime.shift_zone!(DateTime.utc_now(), child.timezone)

      evening =
        if local.hour < 12,
          do: Date.add(DateTime.to_date(local), -1),
          else: DateTime.to_date(local)

      {:ok, plan} =
        Plans.start(
          scope,
          child,
          Phase.for_child(child),
          Map.put(attrs, :started_on, Date.add(evening, -(night - 1)))
        )

      plan
    end

    test "without a plan a 5-month-old gets S.I.T. B.A.C.K., not check-ins", %{
      conn: conn,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")
      assert has_element?(lv, "#night-start", "S.I.T. B.A.C.K.")
      refute has_element?(lv, "#abcs-put-down")
    end

    test "with a plan it offers to put down or to start a waking", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      start_plan(scope, child, 1)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")

      assert has_element?(lv, "#night-idle", "ABCs of Sleep")
      assert has_element?(lv, "#abcs-put-down")
      assert has_element?(lv, "#abcs-cry")
      refute has_element?(lv, "#night-start")
    end

    test "putting down starts a quiet bedtime that waits for crying", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      plan = start_plan(scope, child, 1)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")

      lv |> element("#abcs-put-down") |> render_click()

      assert has_element?(lv, ~s(#night-step[data-phase="waiting"]))
      assert has_element?(lv, "#abcs-waiting")

      assert %{method: :abcs, kind: :bedtime, plan_id: plan_id, events: []} =
               NightWakes.active(scope, child)

      assert plan_id == plan.id
    end

    test "crying starts the pop-in countdown: 5 minutes first", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      start_plan(scope, child, 1)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")
      lv |> element("#abcs-put-down") |> render_click()
      lv |> element("#abcs-record-cry") |> render_click()

      assert has_element?(lv, ~s(#night-step[data-phase="crying"]))
      assert has_element?(lv, "#abcs-state", "pop-in (1)")

      [%{"at" => at}] = NightWakes.active(scope, child).events
      {:ok, cried, _} = DateTime.from_iso8601(at)
      ends = DateTime.to_unix(cried) * 1000 + 300_000
      assert has_element?(lv, ~s(#night-countdown[phx-hook=NightTimer][data-ends-at="#{ends}"]))
    end

    test "a pop-in moves the next one to 10 minutes later", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      start_plan(scope, child, 1)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")
      lv |> element("#abcs-cry") |> render_click()
      lv |> element("#abcs-record-popin") |> render_click()

      assert has_element?(lv, "#abcs-cry-total", "pop-ins: 1")
      assert has_element?(lv, "#abcs-state", "pop-in (2)")
      assert %{events: [_, %{"kind" => "pop_in", "at" => at}]} = NightWakes.active(scope, child)
      {:ok, went_in, _} = DateTime.from_iso8601(at)
      ends = DateTime.to_unix(went_in) * 1000 + 600_000
      assert has_element?(lv, ~s(#night-countdown[data-ends-at="#{ends}"]))
    end

    test "calming waits, and crying again resumes", %{conn: conn, scope: scope, child: child} do
      start_plan(scope, child, 1)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")
      lv |> element("#abcs-cry") |> render_click()
      lv |> element("#abcs-record-calm") |> render_click()

      assert has_element?(lv, ~s(#night-step[data-phase="calming"]))
      assert has_element?(lv, "#abcs-calming", "Wait")
      refute has_element?(lv, "#night-countdown")
      refute has_element?(lv, "#abcs-record-popin")

      lv |> element("#abcs-record-cry") |> render_click()
      assert has_element?(lv, ~s(#night-step[data-phase="crying"]))
    end

    test "falling asleep ends it and reports the crying", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      start_plan(scope, child, 1)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")
      lv |> element("#abcs-cry") |> render_click()
      lv |> element("#abcs-asleep") |> render_click()

      assert has_element?(lv, "#night-idle")
      assert has_element?(lv, "#night-last", "Asleep")
      assert NightWakes.active(scope, child) == nil

      assert [%NightWake{outcome: :settled, cry_seconds: seconds}] =
               NightWakes.recent(scope, child)

      assert is_integer(seconds)
    end

    test "the comfort rule follows the night: touch on night 1, voice from night 3", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      plan = start_plan(scope, child, 1)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")
      lv |> element("#abcs-cry") |> render_click()
      assert has_element?(lv, "#abcs-popin-how", "soothing touch")

      {:ok, _} = Plans.finish(scope, plan, :stopped)
      {:ok, wake} = NightWakes.active(scope, child) |> then(&{:ok, &1})
      {:ok, _} = NightWakes.finish(scope, wake, :stopped)

      start_plan(scope, child, 3)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")
      lv |> element("#abcs-cry") |> render_click()
      assert has_element?(lv, "#abcs-popin-how", "voice only")
    end

    test "tonight's night feeds are listed", %{conn: conn, scope: scope, child: child} do
      start_plan(scope, child, 1, %{
        feed_kind: :nursing,
        feed_times: [1350, 210],
        feed_amounts: [15, 15]
      })

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")

      assert has_element?(lv, "#night-weaning", "22:30: 15 min")
      assert has_element?(lv, "#night-weaning", "asleep 5–10 minutes")
    end

    test "from 11 hours after the put-down it's morning: get them once quiet" do
      now = ~U[2026-10-11 07:00:00Z]

      wake = %NightWake{
        kind: :waking,
        method: :abcs,
        started_at: now,
        events: [Trygg.Sleep.Checkins.event("cry", now)]
      }

      render = fn bedtime ->
        render_component(&TryggWeb.SleepAbcsComponents.abcs_screen/1,
          wake: wake,
          tonight: %{night: 1},
          bedtime_at: bedtime,
          can_write: true,
          now: now,
          tz: "Etc/UTC"
        )
      end

      assert render.(DateTime.add(now, -11 * 3600, :second)) =~ "been 11 hours"
      assert render.(DateTime.add(now, -12 * 3600, :second)) =~ "id=\"abcs-morning\""
      refute render.(DateTime.add(now, -10 * 3600, :second)) =~ "abcs-morning"
      refute render.(nil) =~ "abcs-morning"
    end

    test "no morning banner before 11 hours", %{conn: conn, scope: scope, child: child} do
      plan = start_plan(scope, child, 1)
      {:ok, put_down} = NightWakes.start(scope, child, :abcs, kind: :bedtime, plan_id: plan.id)
      {:ok, _} = NightWakes.asleep(scope, put_down, 0)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")
      lv |> element("#abcs-cry") |> render_click()
      refute has_element?(lv, "#abcs-morning")
    end

    test "either caregiver can run the pop-ins, and a double tap counts once", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      partner = user_fixture(%{first_name: "Sam"})
      membership_fixture(child, partner, :caregiver)
      partner_scope = user_scope_fixture(partner)
      plan = start_plan(scope, child, 1)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")

      {:ok, wake} = NightWakes.start(partner_scope, child, :abcs, plan_id: plan.id)
      assert has_element?(lv, ~s(#night-step[data-phase="crying"]))
      assert has_element?(lv, "#night-started-by", "by Sam")

      {:ok, _} = NightWakes.record(partner_scope, wake, "pop_in", 1)
      assert has_element?(lv, "#abcs-cry-total", "pop-ins: 1")

      # This screen is up to date; a stale tap from the old state does nothing.
      render_click(lv, "record", %{"kind" => "pop_in", "seen" => "1"})
      assert has_element?(lv, "#abcs-cry-total", "pop-ins: 1")
    end

    test "viewers can watch but not run it", %{conn: conn, scope: owner, child: child} do
      plan = start_plan(owner, child, 1)
      %{conn: conn, scope: viewer} = register_and_log_in_user(%{conn: conn})
      membership_fixture(child, viewer.user, :viewer)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")
      refute has_element?(lv, "#abcs-put-down")

      {:ok, _wake} = NightWakes.start(owner, child, :abcs, plan_id: plan.id)
      assert has_element?(lv, ~s(#night-step[data-phase="crying"]))
      refute has_element?(lv, "#abcs-record-popin")
      refute has_element?(lv, "#abcs-asleep")
    end

    test "stopping the plan returns night mode to the age's method", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      plan = start_plan(scope, child, 1)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/night")
      assert has_element?(lv, "#abcs-put-down")

      {:ok, _} = Plans.finish(scope, plan, :stopped)
      assert has_element?(lv, "#night-start", "S.I.T. B.A.C.K.")
      refute has_element?(lv, "#abcs-put-down")
    end
  end
end
