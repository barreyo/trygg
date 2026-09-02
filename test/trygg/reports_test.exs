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
end
