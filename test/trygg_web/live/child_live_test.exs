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

  test "editing renames the child", %{conn: conn, scope: scope} do
    child = child_fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/children/#{child}/edit")

    lv
    |> form("#child-form", child: %{name: "Renamed"})
    |> render_submit()

    assert Families.get_child!(scope, child.id).name == "Renamed"
  end
end
