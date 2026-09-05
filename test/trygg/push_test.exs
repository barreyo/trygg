defmodule Trygg.PushTest do
  # async: false — the deliver/2 tests toggle `config :trygg, Trygg.Push` and
  # the shared test-sender listener, both process-global.
  use Trygg.DataCase, async: false

  import Trygg.AccountsFixtures

  alias Trygg.Push
  alias Trygg.Push.Subscription

  defp sub_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      "endpoint" => "https://push.example.com/#{System.unique_integer([:positive])}",
      "keys" => %{"p256dh" => "BPp256dhKey", "auth" => "authSecret"},
      "user_agent" => "Mozilla/5.0 (Test)"
    })
  end

  describe "subscribe/2" do
    test "stores a subscription from the browser toJSON shape" do
      user = user_fixture()
      attrs = sub_attrs()

      assert {:ok, %Subscription{} = sub} = Push.subscribe(user, attrs)
      assert sub.user_id == user.id
      assert sub.endpoint == attrs["endpoint"]
      assert sub.p256dh == "BPp256dhKey"
      assert sub.auth == "authSecret"
      assert sub.user_agent == "Mozilla/5.0 (Test)"
    end

    test "is idempotent per endpoint: re-subscribing updates the same row" do
      user = user_fixture()
      attrs = sub_attrs()

      assert {:ok, first} = Push.subscribe(user, attrs)

      refreshed =
        attrs
        |> Map.put("keys", %{"p256dh" => "newP256", "auth" => "newAuth"})

      assert {:ok, second} = Push.subscribe(user, refreshed)
      assert second.id == first.id
      assert second.p256dh == "newP256"
      assert Repo.aggregate(Subscription, :count) == 1
    end

    test "an endpoint can move to another user (shared device)" do
      user1 = user_fixture()
      user2 = user_fixture()
      attrs = sub_attrs()

      assert {:ok, first} = Push.subscribe(user1, attrs)
      assert {:ok, second} = Push.subscribe(user2, attrs)
      assert second.id == first.id
      assert second.user_id == user2.id
    end

    test "rejects a payload missing keys" do
      user = user_fixture()
      assert {:error, changeset} = Push.subscribe(user, %{"endpoint" => "https://x/1"})
      assert %{auth: _, p256dh: _} = errors_on(changeset)
    end
  end

  describe "unsubscribe/1" do
    test "removes the row for an endpoint and is a no-op otherwise" do
      user = user_fixture()
      {:ok, sub} = Push.subscribe(user, sub_attrs())

      assert :ok = Push.unsubscribe(sub.endpoint)
      refute Repo.get(Subscription, sub.id)

      assert :ok = Push.unsubscribe("https://push.example.com/never-seen")
    end
  end

  describe "list_for_users/1" do
    test "returns every subscription for the given users, by struct or id" do
      user1 = user_fixture()
      user2 = user_fixture()
      other = user_fixture()

      {:ok, a} = Push.subscribe(user1, sub_attrs())
      {:ok, b} = Push.subscribe(user1, sub_attrs())
      {:ok, c} = Push.subscribe(user2, sub_attrs())
      {:ok, _d} = Push.subscribe(other, sub_attrs())

      ids = fn subs -> subs |> Enum.map(& &1.id) |> Enum.sort() end

      assert ids.(Push.list_for_users([user1, user2])) == Enum.sort([a.id, b.id, c.id])
      assert ids.(Push.list_for_users([user1.id])) == Enum.sort([a.id, b.id])
    end
  end

  describe "deliver/2" do
    setup do
      Trygg.Push.Sender.Test.listen()
      prev = Application.get_env(:trygg, Trygg.Push)
      Application.put_env(:trygg, Trygg.Push, Keyword.put(prev, :enabled, true))
      on_exit(fn -> Application.put_env(:trygg, Trygg.Push, prev) end)
      :ok
    end

    test "sends the encoded payload to each of the user's subscriptions" do
      user = user_fixture()
      {:ok, _} = Push.subscribe(user, sub_attrs())
      {:ok, _} = Push.subscribe(user, sub_attrs())

      assert {:ok, %{sent: 2, pruned: 0, failed: 0}} =
               Push.deliver(user, %{title: "Hi", body: "There", url: "/c/1/vitals"})

      assert_received {:web_push, %{"endpoint" => _, "keys" => %{"p256dh" => _}}, message}

      assert Jason.decode!(message) == %{
               "title" => "Hi",
               "body" => "There",
               "url" => "/c/1/vitals"
             }

      assert_received {:web_push, _, _}
    end

    test "prunes a subscription the push service reports as gone" do
      Trygg.Push.Sender.Test.listen(result: {:error, :expired})
      user = user_fixture()
      {:ok, sub} = Push.subscribe(user, sub_attrs())

      assert {:ok, %{sent: 0, pruned: 1, failed: 0}} =
               Push.deliver(user, %{title: "Bye", body: "Gone"})

      refute Repo.get(Trygg.Push.Subscription, sub.id)
    end

    test "counts other errors as failures without pruning" do
      Trygg.Push.Sender.Test.listen(result: {:error, {:http_error, 500, "boom"}})
      user = user_fixture()
      {:ok, sub} = Push.subscribe(user, sub_attrs())

      assert {:ok, %{sent: 0, pruned: 0, failed: 1}} =
               Push.deliver(user, %{title: "Oops", body: "Retry later"})

      assert Repo.get(Trygg.Push.Subscription, sub.id)
    end

    test "is a quiet no-op when push is disabled" do
      prev = Application.get_env(:trygg, Trygg.Push)
      Application.put_env(:trygg, Trygg.Push, Keyword.put(prev, :enabled, false))
      on_exit(fn -> Application.put_env(:trygg, Trygg.Push, prev) end)

      user = user_fixture()
      {:ok, _} = Push.subscribe(user, sub_attrs())

      assert {:ok, %{sent: 0, pruned: 0, failed: 0}} =
               Push.deliver(user, %{title: "x", body: "y"})

      refute_received {:web_push, _, _}
    end
  end
end
