defmodule TryggWeb.LogSyncControllerTest do
  use TryggWeb.ConnCase, async: true

  import Trygg.FamiliesFixtures

  alias Trygg.Log

  setup %{conn: conn} do
    %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
    child = child_fixture(scope, %{timezone: "Etc/UTC"})

    conn = put_req_header(conn, "content-type", "application/json")
    %{conn: conn, scope: scope, child: child}
  end

  defp diaper(overrides \\ %{}) do
    Map.merge(
      %{
        "client_id" => Ecto.UUID.generate(),
        "type" => "diaper",
        "started_at" =>
          DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.to_iso8601(),
        "data" => %{"kind" => "pee"}
      },
      overrides
    )
  end

  defp post_entries(conn, child, entries) do
    post(conn, ~p"/c/#{child}/log/entries", Jason.encode!(%{"entries" => entries}))
  end

  describe "POST /c/:id/log/entries" do
    test "syncs a batch and reports one result per entry", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      good = diaper()
      bad = diaper(%{"type" => "feeding", "data" => %{"bottle_contents" => "formula"}})

      conn = post_entries(conn, child, [good, bad])

      assert %{"results" => results} = json_response(conn, 200)
      assert [ok, rejected] = results

      assert ok["client_id"] == good["client_id"]
      assert ok["status"] == "ok"
      assert is_integer(ok["id"])

      assert rejected["client_id"] == bad["client_id"]
      assert rejected["status"] == "rejected"
      assert rejected["errors"]["data"]

      assert [entry] = Log.recent_entries(scope, child)
      assert entry.client_id == good["client_id"]
    end

    test "re-POSTing the same batch is idempotent", %{conn: conn, scope: scope, child: child} do
      entries = [diaper(), diaper()]

      assert %{"results" => first} = post_entries(conn, child, entries) |> json_response(200)
      assert Enum.all?(first, &(&1["status"] == "ok"))

      assert %{"results" => second} =
               build_conn()
               |> log_in_user(scope.user)
               |> put_req_header("content-type", "application/json")
               |> post_entries(child, entries)
               |> json_response(200)

      assert Enum.all?(second, &(&1["status"] == "ok"))
      assert Log.recent_entries(scope, child) |> length() == 2
    end

    test "rejects a body without an entries list", %{conn: conn, child: child} do
      conn = post(conn, ~p"/c/#{child}/log/entries", Jason.encode!(%{"entry" => diaper()}))
      assert json_response(conn, 400)["error"]
    end

    test "redirects to log in when not authenticated", %{child: child} do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post_entries(child, [diaper()])

      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "404s for a child the caller is not a member of", %{conn: conn} do
      other_child = child_fixture()

      assert_error_sent 404, fn -> post_entries(conn, other_child, [diaper()]) end
    end

    test "403s for a viewer of the child", %{child: child} do
      viewer = Trygg.AccountsFixtures.user_fixture()
      membership_fixture(child, viewer, :viewer)

      conn =
        build_conn()
        |> log_in_user(viewer)
        |> put_req_header("content-type", "application/json")

      assert_error_sent 403, fn -> post_entries(conn, child, [diaper()]) end
    end

    test "a server_id entry stops a running timer", %{conn: conn, scope: scope, child: child} do
      {:ok, nap} = Log.start_timer(scope, child, :sleep)
      at = DateTime.utc_now() |> DateTime.truncate(:second)

      conn =
        post_entries(conn, child, [
          %{
            "client_id" => Ecto.UUID.generate(),
            "server_id" => nap.id,
            "ended_at" => DateTime.to_iso8601(at)
          }
        ])

      assert %{"results" => [res]} = json_response(conn, 200)
      assert res["status"] == "ok"
      assert res["id"] == nap.id
      assert Log.running_timers(scope, child) == []
    end

    test "a server_id entry for an unknown timer is rejected, not fatal", %{
      conn: conn,
      child: child
    } do
      conn =
        post_entries(conn, child, [
          %{
            "client_id" => Ecto.UUID.generate(),
            "server_id" => 999_999,
            "ended_at" => DateTime.to_iso8601(DateTime.utc_now())
          }
        ])

      assert %{"results" => [res]} = json_response(conn, 200)
      assert res["status"] == "rejected"
      assert res["errors"]["server_id"]
    end
  end
end
