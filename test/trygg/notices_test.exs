defmodule Trygg.NoticesTest do
  use Trygg.DataCase, async: true

  alias Trygg.Notices

  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  setup do
    scope = user_scope_fixture()
    %{scope: scope, child: child_fixture(scope)}
  end

  test "a dismissal hides the notice for seven days, then it returns", %{
    scope: scope,
    child: child
  } do
    now = ~U[2026-09-29 10:00:00Z]

    assert Notices.dismiss(scope, child, ["weight-check"], now) == MapSet.new(["weight-check"])

    assert "weight-check" in Notices.dismissed(scope, child, DateTime.add(now, 6 * 86_400))
    refute "weight-check" in Notices.dismissed(scope, child, DateTime.add(now, 7 * 86_400 + 1))
  end

  test "dismissing again extends the window", %{scope: scope, child: child} do
    now = ~U[2026-09-29 10:00:00Z]
    later = DateTime.add(now, 5 * 86_400)

    Notices.dismiss(scope, child, ["weight-check"], now)
    Notices.dismiss(scope, child, ["weight-check"], later)

    assert "weight-check" in Notices.dismissed(scope, child, DateTime.add(now, 10 * 86_400))
  end

  test "dismissals are personal to the caregiver", %{scope: scope, child: child} do
    other = user_scope_fixture()
    membership_fixture(child, other.user, :caregiver)

    Notices.dismiss(scope, child, ["weight-check"])

    assert Notices.dismissed(other, child) == MapSet.new()
  end
end
