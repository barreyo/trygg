defmodule Trygg.Push.DeliveryWorkerTest do
  # async: false — toggles `config :trygg, Trygg.Push` (process-global) and
  # uses the shared recording sender.
  use Trygg.DataCase, async: false
  use Oban.Testing, repo: Trygg.Repo

  import Trygg.AccountsFixtures

  alias Trygg.Push
  alias Trygg.Push.DeliveryWorker
  alias Trygg.Push.Subscription

  @payload %{"title" => "Hi", "body" => "There", "url" => "/c/1/vitals"}

  setup do
    Trygg.Push.Sender.Test.listen()
    prev = Application.get_env(:trygg, Trygg.Push)
    Application.put_env(:trygg, Trygg.Push, Keyword.put(prev, :enabled, true))
    on_exit(fn -> Application.put_env(:trygg, Trygg.Push, prev) end)
    :ok
  end

  defp subscribe(user, slug \\ "device") do
    {:ok, sub} =
      Push.subscribe(user, %{
        "endpoint" => "https://push.example.com/#{slug}-#{System.unique_integer([:positive])}",
        "keys" => %{"p256dh" => "BP#{slug}", "auth" => "auth-#{slug}"}
      })

    sub
  end

  test "delivers the encoded payload to the subscription" do
    sub = subscribe(user_fixture())

    assert :ok = perform_job(DeliveryWorker, %{subscription_id: sub.id, payload: @payload})

    assert_received {:web_push, %{"endpoint" => endpoint}, message}
    assert endpoint == sub.endpoint
    assert Jason.decode!(message) == @payload
  end

  test "prunes the subscription and succeeds when the push service reports it gone" do
    Trygg.Push.Sender.Test.listen(result: {:error, :expired})
    sub = subscribe(user_fixture())

    assert :ok = perform_job(DeliveryWorker, %{subscription_id: sub.id, payload: @payload})
    refute Repo.get(Subscription, sub.id)
  end

  test "returns an error so the job retries on a transient failure" do
    Trygg.Push.Sender.Test.listen(result: {:error, {:http_error, 500, "boom"}})
    sub = subscribe(user_fixture())

    assert {:error, {:http_error, 500, _}} =
             perform_job(DeliveryWorker, %{subscription_id: sub.id, payload: @payload})

    assert Repo.get(Subscription, sub.id), "a transient failure must not prune the subscription"
  end

  test "is a no-op when the subscription is already gone" do
    assert :ok = perform_job(DeliveryWorker, %{subscription_id: 0, payload: @payload})
    refute_received {:web_push, _, _}
  end

  test "is a no-op when push is disabled" do
    prev = Application.get_env(:trygg, Trygg.Push)
    Application.put_env(:trygg, Trygg.Push, Keyword.put(prev, :enabled, false))
    on_exit(fn -> Application.put_env(:trygg, Trygg.Push, prev) end)

    sub = subscribe(user_fixture())

    assert :ok = perform_job(DeliveryWorker, %{subscription_id: sub.id, payload: @payload})
    refute_received {:web_push, _, _}
  end

  describe "Push.enqueue/2" do
    test "inserts one job per subscription with a trimmed, string-keyed payload" do
      user = user_fixture()
      a = subscribe(user, "a")
      b = subscribe(user, "b")

      assert :ok =
               Push.enqueue(user, %{
                 title: "T",
                 body: "B",
                 url: "/x",
                 tag: "t",
                 extra: "dropped"
               })

      for sub <- [a, b] do
        assert_enqueued(
          worker: DeliveryWorker,
          args: %{
            "subscription_id" => sub.id,
            "payload" => %{"title" => "T", "body" => "B", "url" => "/x", "tag" => "t"}
          }
        )
      end
    end

    test "enqueues nothing when push is disabled" do
      prev = Application.get_env(:trygg, Trygg.Push)
      Application.put_env(:trygg, Trygg.Push, Keyword.put(prev, :enabled, false))
      on_exit(fn -> Application.put_env(:trygg, Trygg.Push, prev) end)

      user = user_fixture()
      subscribe(user)

      assert :ok = Push.enqueue(user, %{title: "T", body: "B"})
      refute_enqueued(worker: DeliveryWorker)
    end
  end
end
