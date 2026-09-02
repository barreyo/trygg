defmodule TryggWeb.CaregiverLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.Families

  test "an owner can send an invite", %{conn: conn} do
    %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
    child = child_fixture(scope)

    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/caregivers")

    lv
    |> form("#invite-form", invite: %{email: "co@example.com", role: "caregiver"})
    |> render_submit()

    assert_redirect(lv, ~p"/c/#{child}/caregivers")
    assert [invite] = Families.list_invites(scope, child)
    assert invite.email == "co@example.com"

    {:ok, _lv, html} = live(conn, ~p"/c/#{child}/caregivers")
    assert html =~ "co@example.com"
    assert html =~ "Pending invites"
  end

  test "a non-owner caregiver does not see the invite form", %{conn: conn} do
    owner_scope = user_scope_fixture()
    child = child_fixture(owner_scope)

    caregiver = user_fixture()
    membership_fixture(child, caregiver, :caregiver)
    conn = log_in_user(conn, caregiver)

    {:ok, _lv, html} = live(conn, ~p"/c/#{child}/caregivers")

    refute html =~ "invite-form"
    assert html =~ caregiver.email
  end
end
