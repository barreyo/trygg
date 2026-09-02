defmodule TryggWeb.ChildLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.FamiliesFixtures

  alias Trygg.Families

  setup :register_and_log_in_user

  test "lists the current user's children with their role", %{conn: conn, scope: scope} do
    child = child_fixture(scope)
    {:ok, _lv, html} = live(conn, ~p"/children")
    assert html =~ child.name
    assert html =~ "owner"
  end

  test "creating a child adds an owner membership and opens the dashboard", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/children/new")

    {:error, {:live_redirect, %{to: path}}} =
      lv
      |> form("#child-form", child: %{name: "Pip", timezone: "Etc/UTC"})
      |> render_submit()

    assert [child] = Families.list_children(scope)
    assert child.name == "Pip"
    assert child.role == :owner
    assert path == ~p"/c/#{child}"
  end

  test "the list updates live when a child is added from another session", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, html} = live(conn, ~p"/children")
    refute html =~ "Newbie"

    {:ok, _} = Families.create_child(scope, %{name: "Newbie", timezone: "Etc/UTC"})

    assert render(lv) =~ "Newbie"
  end

  test "the list reflects a live rename by a co-owner", %{conn: conn, scope: scope} do
    child = child_fixture(scope)
    {:ok, lv, html} = live(conn, ~p"/children")
    assert html =~ child.name

    {:ok, _} = Families.update_child(scope, child, %{name: "Pipkin"})

    assert render(lv) =~ "Pipkin"
    refute render(lv) =~ child.name
  end

  test "editing renames the child", %{conn: conn, scope: scope} do
    child = child_fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/children/#{child}/edit")

    lv
    |> form("#child-form", child: %{name: "Renamed"})
    |> render_submit()

    assert Families.get_child!(scope, child.id).name == "Renamed"
  end

  test "owners can reach the edit form from the list", %{conn: conn, scope: scope} do
    child = child_fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/children")

    {:ok, _edit_lv, html} =
      lv
      |> element("#edit-child-#{child.id}")
      |> render_click()
      |> follow_redirect(conn, ~p"/children/#{child}/edit")

    assert html =~ "Edit #{child.name}"
  end

  test "the edit form leads back to the child's page", %{conn: conn, scope: scope} do
    child = child_fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/children/#{child}/edit")

    assert has_element?(lv, "header a[aria-label=Back][href='#{~p"/c/#{child}"}']")
    assert has_element?(lv, "#child-form a[href='#{~p"/c/#{child}"}']", "Cancel")
  end

  test "caregivers can't edit a child they don't own", %{conn: conn} do
    %{child: child, member: member} = shared_child_fixture(:caregiver)
    conn = log_in_user(conn, member)

    {:ok, lv, _html} = live(conn, ~p"/children")
    refute has_element?(lv, "#edit-child-#{child.id}")

    assert {:error, {:live_redirect, %{to: path, flash: flash}}} =
             live(conn, ~p"/children/#{child}/edit")

    assert path == ~p"/c/#{child}"
    assert flash["error"] =~ "owners can edit"
  end
end
