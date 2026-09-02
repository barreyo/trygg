defmodule TryggWeb.TimelineLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.FamiliesFixtures
  import Trygg.LogFixtures

  alias Trygg.Log

  setup %{conn: conn} do
    %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
    %{conn: conn, scope: scope, child: child_fixture(scope)}
  end

  test "shows entries and filters by type", %{conn: conn, scope: scope, child: child} do
    entry_fixture(scope, child, type: :feeding)
    entry_fixture(scope, child, type: :diaper)

    {:ok, lv, html} = live(conn, ~p"/c/#{child}/log")
    assert html =~ "Bottle"
    assert html =~ "diaper"

    filtered = lv |> element("button", "Diapers") |> render_click()
    assert filtered =~ "diaper"
    refute filtered =~ "Bottle"
  end

  test "editing an entry updates its note", %{conn: conn, scope: scope, child: child} do
    entry = entry_fixture(scope, child, type: :diaper)

    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/log")
    lv |> element(~s([id$="#{entry.id}"])) |> render_click()

    lv
    |> form("#edit-entry-form", entry: %{note: "leaked"})
    |> render_submit()

    assert Log.get_entry!(scope, entry.id).note == "leaked"
  end

  test "deleting an entry removes it", %{conn: conn, scope: scope, child: child} do
    entry = entry_fixture(scope, child, type: :diaper)

    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/log")
    lv |> element(~s([id$="#{entry.id}"])) |> render_click()
    lv |> element("button", "Delete") |> render_click()

    assert Log.list_entries(scope, child) == []
  end
end
