defmodule TryggWeb.CaregiverLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.{ApiTokens, Families}

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

  test "an owner can invite someone in simple mode", %{conn: conn} do
    %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
    child = child_fixture(scope)

    {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/caregivers")

    lv
    |> form("#invite-form", invite: %{email: "nanny@example.com", role: "simple"})
    |> render_submit()

    assert [%{role: :simple}] = Families.list_invites(scope, child)
  end

  test "an owner can put a caregiver into simple mode, and back", %{conn: conn} do
    %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
    child = child_fixture(scope)
    nanny = user_fixture()
    membership = membership_fixture(child, nanny, :caregiver)

    {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/caregivers")

    # Only other members' roles are theirs to set: not their own, nor an owner's.
    assert has_element?(lv, "#member-role-#{membership.id}")

    assert [_] =
             lv
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("select[id^=member-role-]")
             |> Enum.to_list()

    lv
    |> form("#member-role-form-#{membership.id}", role: "simple")
    |> render_change()

    assert Families.family_role(user_scope_fixture(nanny), child.family_id) == :simple
    assert render(lv) =~ "is now simple mode"

    lv
    |> form("#member-role-form-#{membership.id}", role: "caregiver")
    |> render_change()

    assert Families.family_role(user_scope_fixture(nanny), child.family_id) == :caregiver
  end

  test "a caregiver can't change anyone's role", %{conn: conn} do
    %{child: child, member: member} = shared_child_fixture(:caregiver)
    membership_fixture(child, user_fixture(), :caregiver)

    {:ok, lv, _html} = live_loaded(log_in_user(conn, member), ~p"/c/#{child}/caregivers")

    refute render(lv) =~ "member-role-form"
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

  describe "API access" do
    test "creating a token shows its secret once, then lists it", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      child = child_fixture(scope)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/caregivers")

      refute has_element?(lv, "#new-api-token")

      lv
      |> form("#api-token-form", token: %{name: "Home Assistant", role: "caregiver"})
      |> render_submit()

      assert has_element?(lv, "#new-api-token-secret", "trygg_")
      assert [token] = ApiTokens.list_tokens(scope, child.family_id)
      assert token.name == "Home Assistant"
      assert has_element?(lv, "#api-token-#{token.id}")

      lv |> element("#new-api-token button", "Done") |> render_click()
      refute has_element?(lv, "#new-api-token")
      assert has_element?(lv, "#api-token-#{token.id}")
    end

    test "a blank name is rejected", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      child = child_fixture(scope)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/caregivers")

      lv |> form("#api-token-form", token: %{name: "", role: "viewer"}) |> render_submit()

      refute has_element?(lv, "#new-api-token")
      assert ApiTokens.list_tokens(scope, child.family_id) == []
    end

    test "a token can be revoked", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      child = child_fixture(scope)
      {:ok, token} = ApiTokens.create_token(scope, child.family_id, %{name: "Old", role: :viewer})
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/caregivers")

      lv |> element("#api-token-#{token.id} button", "Revoke") |> render_click()

      refute has_element?(lv, "#api-token-#{token.id}")
      assert :error = ApiTokens.authenticate(token.secret)
    end

    test "a viewer can only issue read-only tokens", %{conn: conn} do
      %{owner_scope: _owner, child: child, member: member} = shared_child_fixture(:viewer)
      conn = log_in_user(conn, member)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/caregivers")

      assert has_element?(lv, "#api-token-form")
      refute has_element?(lv, "#api-token-form option[value='caregiver']")
      assert has_element?(lv, "#api-token-form option[value='viewer']")
    end
  end
end
