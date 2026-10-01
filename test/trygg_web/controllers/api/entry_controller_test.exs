defmodule TryggWeb.Api.EntryControllerTest do
  use TryggWeb.ConnCase, async: true

  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.{ApiTokens, Log}

  setup %{conn: conn} do
    scope = user_scope_fixture()
    child = child_fixture(scope)
    conn = put_req_header(conn, "content-type", "application/json")
    %{conn: conn, scope: scope, child: child}
  end

  defp bearer(conn, scope, child, role \\ :caregiver) do
    {:ok, token} = ApiTokens.create_token(scope, child.family_id, %{name: "test", role: role})
    put_req_header(conn, "authorization", "Bearer " <> token.secret)
  end

  defp post_json(conn, path, body), do: post(conn, path, Jason.encode!(body))

  describe "GET /api/v1/children/:child_id/entries" do
    test "lists entries newest first and filters by type", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, _} = Log.create_entry(scope, child, :diaper, %{"data" => %{"kind" => "pee"}})
      {:ok, _} = Log.create_entry(scope, child, :feeding, %{"data" => %{"amount_ml" => 90}})

      conn = bearer(conn, scope, child, :viewer)

      assert %{"data" => all} =
               conn |> get(~p"/api/v1/children/#{child.id}/entries") |> json_response(200)

      assert length(all) == 2

      assert %{"data" => [%{"type" => "feeding", "data" => %{"amount_ml" => amount}}]} =
               conn
               |> get(~p"/api/v1/children/#{child.id}/entries?type=feeding&limit=5")
               |> json_response(200)

      assert amount == 90
    end

    test "rejects bad filters", %{conn: conn, scope: scope, child: child} do
      conn = bearer(conn, scope, child, :viewer)

      assert %{"errors" => %{"type" => _}} =
               conn
               |> get(~p"/api/v1/children/#{child.id}/entries?type=nap")
               |> json_response(422)

      assert %{"errors" => %{"since" => _}} =
               conn
               |> get(~p"/api/v1/children/#{child.id}/entries?since=yesterday")
               |> json_response(422)

      assert %{"errors" => %{"limit" => _}} =
               conn |> get(~p"/api/v1/children/#{child.id}/entries?limit=0") |> json_response(422)
    end

    test "is a 404 for a child outside the token's family", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      elsewhere = child_fixture(scope)
      conn = bearer(conn, scope, child)

      assert_error_sent 404, fn -> get(conn, ~p"/api/v1/children/#{elsewhere.id}/entries") end
    end
  end

  describe "POST /api/v1/children/:child_id/entries" do
    test "logs an entry as the token's issuer", %{conn: conn, scope: scope, child: child} do
      conn =
        conn
        |> bearer(scope, child)
        |> post_json(~p"/api/v1/children/#{child.id}/entries", %{
          type: "feeding",
          data: %{amount_ml: 120, bottle_contents: "formula"},
          note: "from the fridge"
        })

      assert %{"data" => %{"id" => id, "type" => "feeding", "running" => false}} =
               json_response(conn, 201)

      entry = Log.get_entry!(scope, id)
      assert entry.logged_by_id == scope.user.id
      assert entry.note == "from the fridge"
    end

    test "a read-only token is a 403 and logs nothing", %{conn: conn, scope: scope, child: child} do
      conn = bearer(conn, scope, child, :viewer)

      assert_error_sent 403, fn ->
        post_json(conn, ~p"/api/v1/children/#{child.id}/entries", %{
          type: "diaper",
          data: %{kind: "pee"}
        })
      end

      assert Log.list_entries(scope, child) == []
    end

    test "validates the type and the entry", %{conn: conn, scope: scope, child: child} do
      conn = bearer(conn, scope, child)
      path = ~p"/api/v1/children/#{child.id}/entries"

      assert %{"errors" => %{"type" => ["can't be blank"]}} =
               conn |> post_json(path, %{}) |> json_response(422)

      assert %{"errors" => %{"type" => ["is invalid"]}} =
               conn |> post_json(path, %{type: "nap"}) |> json_response(422)

      assert %{"errors" => %{"data" => _}} =
               conn |> post_json(path, %{type: "feeding"}) |> json_response(422)
    end

    test "a sleep with no end starts the running timer, once", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      conn = bearer(conn, scope, child)
      path = ~p"/api/v1/children/#{child.id}/entries"

      assert %{"data" => %{"id" => id, "running" => true, "ended_at" => nil}} =
               conn |> post_json(path, %{type: "sleep"}) |> json_response(201)

      assert %{"data" => %{"id" => ^id}} =
               conn |> post_json(path, %{type: "sleep", ended_at: nil}) |> json_response(201)
    end

    test "a client_id makes the call idempotent", %{conn: conn, scope: scope, child: child} do
      conn = bearer(conn, scope, child)
      path = ~p"/api/v1/children/#{child.id}/entries"

      body = %{
        type: "diaper",
        data: %{kind: "pee"},
        started_at: DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60)),
        client_id: Ecto.UUID.generate()
      }

      assert %{"data" => %{"id" => id}} = conn |> post_json(path, body) |> json_response(201)
      assert %{"data" => %{"id" => ^id}} = conn |> post_json(path, body) |> json_response(201)
      assert [_one] = Log.list_entries(scope, child)

      assert %{"errors" => %{"client_id" => _}} =
               conn |> post_json(path, %{body | client_id: "nope"}) |> json_response(422)
    end

    test "is a 404 for a child outside the token's family", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      elsewhere = child_fixture(scope)

      conn = bearer(conn, scope, child)

      assert_error_sent 404, fn ->
        post_json(conn, ~p"/api/v1/children/#{elsewhere.id}/entries", %{
          type: "diaper",
          data: %{kind: "pee"}
        })
      end

      assert Log.list_entries(scope, elsewhere) == []
    end
  end

  describe "POST .../entries/:id/stop" do
    test "stops a running timer", %{conn: conn, scope: scope, child: child} do
      {:ok, timer} = Log.start_timer(scope, child, :sleep)
      conn = bearer(conn, scope, child)

      conn =
        post_json(conn, ~p"/api/v1/children/#{child.id}/entries/#{timer.id}/stop", %{
          note: "good one"
        })

      assert %{"data" => %{"running" => false, "note" => "good one"}} = json_response(conn, 200)
    end

    test "is a 409 for an entry that isn't running", %{conn: conn, scope: scope, child: child} do
      {:ok, entry} = Log.create_entry(scope, child, :diaper, %{"data" => %{"kind" => "pee"}})
      conn = bearer(conn, scope, child)

      assert conn
             |> post_json(~p"/api/v1/children/#{child.id}/entries/#{entry.id}/stop", %{})
             |> json_response(409)
    end
  end

  describe "DELETE .../entries/:id" do
    test "deletes an entry", %{conn: conn, scope: scope, child: child} do
      {:ok, entry} = Log.create_entry(scope, child, :diaper, %{"data" => %{"kind" => "pee"}})

      conn =
        conn
        |> bearer(scope, child)
        |> delete(~p"/api/v1/children/#{child.id}/entries/#{entry.id}")

      assert response(conn, 204)
      assert Log.list_entries(scope, child) == []
    end

    test "a read-only token can't", %{conn: conn, scope: scope, child: child} do
      {:ok, entry} = Log.create_entry(scope, child, :diaper, %{"data" => %{"kind" => "pee"}})

      conn = bearer(conn, scope, child, :viewer)

      assert_error_sent 403, fn ->
        delete(conn, ~p"/api/v1/children/#{child.id}/entries/#{entry.id}")
      end

      assert [_] = Log.list_entries(scope, child)
    end

    test "an entry of another family's child is a 404", %{conn: conn, scope: scope, child: child} do
      elsewhere = child_fixture(scope)
      {:ok, entry} = Log.create_entry(scope, elsewhere, :diaper, %{"data" => %{"kind" => "pee"}})

      conn = bearer(conn, scope, child)

      assert_error_sent 404, fn ->
        delete(conn, ~p"/api/v1/children/#{child.id}/entries/#{entry.id}")
      end

      assert [_] = Log.list_entries(scope, elsewhere)
    end
  end
end
