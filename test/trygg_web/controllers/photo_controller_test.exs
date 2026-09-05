defmodule TryggWeb.PhotoControllerTest do
  use TryggWeb.ConnCase

  import Trygg.FamiliesFixtures
  import Trygg.LogFixtures

  alias Trygg.Log

  setup %{conn: conn} do
    %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
    child = child_fixture(scope, %{timezone: "Etc/UTC"})
    %{conn: conn, scope: scope, child: child}
  end

  defp entry_with_photo(scope, child, content_type \\ "image/png") do
    {:ok, attrs} = Log.store_photo(child, tiny_png(), content_type)

    {:ok, entry} =
      Log.create_entry(scope, child, :diaper, Map.merge(%{"data" => %{"kind" => "pee"}}, attrs))

    entry
  end

  test "streams the photo bytes to a member", %{conn: conn, scope: scope, child: child} do
    entry = entry_with_photo(scope, child)

    conn = get(conn, ~p"/c/#{child}/log/#{entry.id}/photo")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "cache-control") == ["private, max-age=86400"]
    assert conn.resp_body == tiny_png()
  end

  test "redirects to log in when not authenticated", %{scope: scope, child: child} do
    entry = entry_with_photo(scope, child)
    conn = get(build_conn(), ~p"/c/#{child}/log/#{entry.id}/photo")
    assert redirected_to(conn) == ~p"/users/log-in"
  end

  test "403s for someone who isn't a member of the child", %{scope: scope, child: child} do
    entry = entry_with_photo(scope, child)
    %{conn: other_conn} = register_and_log_in_user(%{conn: build_conn()})

    assert_error_sent 403, fn ->
      get(other_conn, ~p"/c/#{child}/log/#{entry.id}/photo")
    end
  end

  test "404s when the entry has no photo", %{conn: conn, scope: scope, child: child} do
    {:ok, entry} = Log.create_entry(scope, child, :diaper, %{"data" => %{"kind" => "pee"}})

    conn = get(conn, ~p"/c/#{child}/log/#{entry.id}/photo")
    assert conn.status == 404
  end

  test "404s when the entry belongs to a different child", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    other_child = child_fixture(scope, %{timezone: "Etc/UTC"})
    entry = entry_with_photo(scope, other_child)

    conn = get(conn, ~p"/c/#{child}/log/#{entry.id}/photo")
    assert conn.status == 404
  end
end
