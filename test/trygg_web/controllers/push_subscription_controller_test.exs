defmodule TryggWeb.PushSubscriptionControllerTest do
  use TryggWeb.ConnCase, async: true

  alias Trygg.Push
  alias Trygg.Push.Subscription
  alias Trygg.Repo

  @sub %{
    "endpoint" => "https://push.example.com/abc123",
    "keys" => %{"p256dh" => "BPclientPublicKey", "auth" => "clientAuthSecret"}
  }

  describe "POST /push/subscriptions" do
    setup :register_and_log_in_user

    test "stores the subscription for the current user", %{conn: conn, user: user} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("user-agent", "TestAgent/1.0")
        |> post(~p"/push/subscriptions", Jason.encode!(@sub))

      assert response(conn, 201)

      assert [sub] = Push.list_for_users([user])
      assert sub.endpoint == @sub["endpoint"]
      assert sub.p256dh == "BPclientPublicKey"
      assert sub.auth == "clientAuthSecret"
      assert sub.user_agent == "TestAgent/1.0"
    end

    test "re-POSTing the same endpoint updates rather than duplicates", %{user: user} do
      post_sub = fn ->
        build_conn()
        |> log_in_user(user)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/push/subscriptions", Jason.encode!(@sub))
      end

      assert response(post_sub.(), 201)
      assert response(post_sub.(), 201)
      assert Push.list_for_users([user]) |> length() == 1
    end

    test "422 on a malformed payload", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/push/subscriptions", Jason.encode!(%{"endpoint" => "https://x/1"}))

      assert response(conn, 422)
    end
  end

  describe "DELETE /push/subscriptions" do
    setup :register_and_log_in_user

    test "removes the subscription for the given endpoint", %{conn: conn, user: user} do
      {:ok, sub} =
        Push.subscribe(user, %{
          "endpoint" => @sub["endpoint"],
          "keys" => @sub["keys"]
        })

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> delete(~p"/push/subscriptions", Jason.encode!(%{"endpoint" => sub.endpoint}))

      assert response(conn, 204)
      refute Repo.get(Subscription, sub.id)
    end

    test "400 when no endpoint is given", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> delete(~p"/push/subscriptions", Jason.encode!(%{}))

      assert response(conn, 400)
    end
  end

  test "requires authentication", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/push/subscriptions", Jason.encode!(@sub))

    assert redirected_to(conn) == ~p"/users/log-in"
  end
end
