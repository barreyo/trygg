defmodule TryggWeb.InviteLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.Families

  test "the invited user accepts and joins the child", %{conn: conn} do
    owner = user_scope_fixture()
    child = child_fixture(owner)

    invitee = user_fixture()
    invite = invite_fixture(owner, child, email: invitee.email, role: :caregiver)

    conn = log_in_user(conn, invitee)
    {:ok, lv, html} = live(conn, ~p"/invites/#{invite.token}")
    assert html =~ child.name

    {:error, {:live_redirect, %{to: path}}} =
      lv |> element("button", "Accept invitation") |> render_click()

    assert path == ~p"/c/#{child}"
    assert Families.member_role(user_scope_fixture(invitee), child) == :caregiver
  end

  test "a signed-in user whose email doesn't match sees a mismatch notice", %{conn: conn} do
    owner = user_scope_fixture()
    child = child_fixture(owner)
    invite = invite_fixture(owner, child, email: "intended@example.com")

    %{conn: conn} = register_and_log_in_user(%{conn: conn})
    {:ok, _lv, html} = live(conn, ~p"/invites/#{invite.token}")

    assert html =~ "Wrong account"
    assert html =~ "intended@example.com"
  end

  test "an unknown token shows not found", %{conn: conn} do
    %{conn: conn} = register_and_log_in_user(%{conn: conn})
    {:ok, _lv, html} = live(conn, ~p"/invites/nope-nope")
    assert html =~ "Invitation not found"
  end
end
