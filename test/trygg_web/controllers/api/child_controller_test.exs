defmodule TryggWeb.Api.ChildControllerTest do
  use TryggWeb.ConnCase, async: true

  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.ApiTokens

  defp bearer(conn, secret), do: put_req_header(conn, "authorization", "Bearer " <> secret)

  defp token_for(scope, child, role \\ :caregiver) do
    {:ok, token} = ApiTokens.create_token(scope, child.family_id, %{name: "test", role: role})
    token.secret
  end

  describe "authentication" do
    test "a missing, malformed or unknown token is a 401", %{conn: conn} do
      for headers <- [
            [],
            [{"authorization", "Bearer nope"}],
            [{"authorization", "Basic abc"}],
            [{"authorization", "Bearer"}]
          ] do
        conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
        conn = get(conn, ~p"/api/v1/children")

        assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
        assert [~s(Bearer realm="trygg")] = get_resp_header(conn, "www-authenticate")
      end
    end

    test "a browser session isn't enough", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      assert conn |> get(~p"/api/v1/children") |> json_response(401)
    end

    test "the scheme is case-insensitive", %{conn: conn} do
      scope = user_scope_fixture()
      secret = token_for(scope, child_fixture(scope))

      conn =
        conn |> put_req_header("authorization", "bearer " <> secret) |> get(~p"/api/v1/children")

      assert json_response(conn, 200)
    end

    test "a revoked token is a 401", %{conn: conn} do
      scope = user_scope_fixture()
      child = child_fixture(scope)
      {:ok, token} = ApiTokens.create_token(scope, child.family_id, %{name: "x", role: :viewer})
      {:ok, _} = ApiTokens.revoke_token(scope, token)

      assert conn |> bearer(token.secret) |> get(~p"/api/v1/children") |> json_response(401)
    end
  end

  describe "GET /api/v1/children" do
    test "lists the children in the token's family, and only those", %{conn: conn} do
      scope = user_scope_fixture()
      child = child_fixture(scope, %{name: "Alma"})
      sibling = child_fixture(scope, %{name: "Otto"}, family_id: child.family_id)
      _elsewhere = child_fixture(scope, %{name: "Other family"})

      conn = conn |> bearer(token_for(scope, child, :viewer)) |> get(~p"/api/v1/children")

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.sort(Enum.map(data, & &1["name"])) == ["Alma", "Otto"]
      assert Enum.all?(data, &(&1["role"] == "viewer"))
      assert sibling.id in Enum.map(data, & &1["id"])
    end

    test "GET /api/v1/children/:id is a 404 outside the family", %{conn: conn} do
      scope = user_scope_fixture()
      child = child_fixture(scope)
      elsewhere = child_fixture(scope)
      conn = bearer(conn, token_for(scope, child))

      assert %{"data" => %{"id" => id}} =
               conn |> get(~p"/api/v1/children/#{child.id}") |> json_response(200)

      assert id == child.id

      assert_error_sent 404, fn -> get(conn, ~p"/api/v1/children/#{elsewhere.id}") end
    end
  end
end
