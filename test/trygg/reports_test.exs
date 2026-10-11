defmodule Trygg.ReportsTest do
  use Trygg.DataCase, async: true

  alias Trygg.Reports

  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures
  import Trygg.LogFixtures

  setup do
    scope = user_scope_fixture()
    child = child_fixture(scope, %{timezone: "Etc/UTC"})
    %{scope: scope, child: child}
  end

  test "day/4 authorizes viewers and segments log entries", %{scope: scope, child: child} do
    started = ~U[2026-03-02 10:00:00Z]
    ended = ~U[2026-03-02 11:30:00Z]

    entry_fixture(scope, child, %{
      :type => :sleep,
      "started_at" => started,
      "ended_at" => ended
    })

    day = Reports.day(scope, child, ~D[2026-03-02], ~U[2026-03-03 12:00:00Z])
    assert day.date == ~D[2026-03-02]
    assert day.total_sleep_seconds == 90 * 60
  end

  test "summary/4 covers the requested window", %{scope: scope, child: child} do
    summary = Reports.summary(scope, child, 7, DateTime.utc_now())
    assert summary.sample_days == 7
    refute summary.ready?
  end

  test "summary/4 :all spans from the first log day", %{scope: scope, child: child} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    started = DateTime.add(now, -20 * 86_400, :second)

    entry_fixture(scope, child, %{
      :type => :sleep,
      "started_at" => started,
      "ended_at" => DateTime.add(started, 3600, :second)
    })

    summary = Reports.summary(scope, child, :all, now)
    assert summary.sample_days >= 21
    assert summary.sample_days <= 22
  end

  test "viewers may read reports, strangers may not", %{child: child} do
    viewer_user = user_fixture()
    membership_fixture(child, viewer_user, :viewer)
    viewer = user_scope_fixture(viewer_user)

    assert %Trygg.Reports.Day{} = Reports.day(viewer, child, Date.utc_today())

    stranger = user_scope_fixture()

    assert_raise Trygg.Families.NotAuthorizedError, fn ->
      Reports.day(stranger, child, Date.utc_today())
    end
  end

  test "create_child defaults day and night starts", %{scope: scope} do
    child = child_fixture(scope)
    assert child.day_start == ~T[08:00:00]
    assert child.night_start == ~T[20:00:00]
  end

  describe "learning from sleepy cues" do
    # Three past days of naps where the "ready" cue comes after 60 minutes awake
    # but the typical wake window is 75 (median of 60, 90, 60, 105).
    defp log_cue_days(scope, child) do
      today = Date.utc_today()

      for back <- 3..1//-1 do
        date = Date.add(today, -back)
        at = fn h, m -> DateTime.new!(date, Time.new!(h, m, 0), "Etc/UTC") end

        for {from, to, cue} <- [
              {at.(8, 0), at.(8, 45), nil},
              {at.(9, 45), at.(10, 30), "ready"},
              {at.(12, 0), at.(12, 45), nil},
              {at.(13, 45), at.(14, 30), "ready"},
              {at.(16, 15), at.(17, 0), nil}
            ] do
          data = if cue, do: %{"cue" => cue}, else: %{}

          entry_fixture(scope, child, %{
            :type => :sleep,
            "started_at" => from,
            "ended_at" => to,
            "data" => data
          })
        end
      end
    end

    test "summary/4 reports the adjustment and applies it to the prediction", %{
      scope: scope,
      child: child
    } do
      log_cue_days(scope, child)

      summary = Reports.summary(scope, child, 14)

      assert %{factor: factor, n_ready: 6, ready_seconds: 3600, overall_seconds: 4500} =
               summary.cue_adjustment

      assert_in_delta factor, 0.9, 0.001
      assert summary.prediction.cue_factor == factor
    end

    test "no adjustment without enough cued sleeps", %{scope: scope, child: child} do
      assert Reports.summary(scope, child, 14).cue_adjustment == nil
      assert Reports.summary(scope, child, 14).prediction.cue_factor == 1.0
    end
  end
end
