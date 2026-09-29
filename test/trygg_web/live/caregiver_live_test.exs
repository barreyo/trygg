defmodule TryggWeb.CaregiverLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.Families

  test "an owner can send an invite", %{conn: conn} do
    %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
    child = child_fixture(scope)

    {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/caregivers")

    lv
    |> form("#invite-form", invite: %{email: "co@example.com", role: "caregiver"})
    |> render_submit()

    assert_redirect(lv, ~p"/c/#{child}/caregivers")
    assert [invite] = Families.list_invites(scope, child)
    assert invite.email == "co@example.com"

    {:ok, _lv, html} = live_loaded(conn, ~p"/c/#{child}/caregivers")
    assert html =~ "co@example.com"
    assert html =~ "Pending invites"
  end

  test "the heading updates when the child is renamed elsewhere", %{conn: conn} do
    %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
    child = child_fixture(scope)

    {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/caregivers")

    {:ok, _} = Families.update_child(scope, child, %{name: "Juniper"})

    assert render(lv) =~ "Juniper"
  end

  test "a removed caregiver is bounced from the sharing page", %{conn: conn} do
    owner_scope = user_scope_fixture()
    child = child_fixture(owner_scope)

    caregiver = user_fixture()
    membership = membership_fixture(child, caregiver, :caregiver)
    conn = log_in_user(conn, caregiver)

    {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/caregivers")

    {:ok, _} = Families.remove_member(owner_scope, child, membership)

    assert_redirect(lv, ~p"/")
  end

  test "a non-owner caregiver does not see the invite form", %{conn: conn} do
    owner_scope = user_scope_fixture()
    child = child_fixture(owner_scope)

    caregiver = user_fixture()
    membership_fixture(child, caregiver, :caregiver)
    conn = log_in_user(conn, caregiver)

    {:ok, _lv, html} = live_loaded(conn, ~p"/c/#{child}/caregivers")

    refute html =~ "invite-form"
    assert html =~ caregiver.email
  end
end
