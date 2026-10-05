defmodule Trygg.Log.VitaminDRemindersTest do
  # async: false — flips `config :trygg, Trygg.Push` (process-global) and uses
  # the shared recording sender.
  use Trygg.DataCase, async: false

  import Trygg.FamiliesFixtures

  alias Trygg.Families
  alias Trygg.Families.Child
  alias Trygg.Log
  alias Trygg.Log.VitaminDReminders
  alias Trygg.Repo

  # Push fans out through `Trygg.Push.DeliveryWorker` jobs; run the scan with
  # Oban inline so the recording sender fires synchronously.
  defp run_scan(now_fun),
    do: Oban.Testing.with_testing_mode(:inline, fn -> VitaminDReminders.run(now_fun) end)

  # A fixed "child-local now" at `hh:mm` on the child's real current date.
  defp at(child, hh, mm) do
    child
    |> Child.local_today()
    |> DateTime.new!(Time.new!(hh, mm, 0), child.timezone)
    |> then(&fn _child -> &1 end)
  end

  setup do
    Trygg.Push.Sender.Test.listen()
    prev = Application.get_env(:trygg, Trygg.Push)
    Application.put_env(:trygg, Trygg.Push, Keyword.put(prev, :enabled, true))
    on_exit(fn -> Application.put_env(:trygg, Trygg.Push, prev) end)

    %{owner_scope: owner, child: child, member: member} = shared_child_fixture(:caregiver)
    {:ok, child} = Families.update_child(owner, child, %{vitamin_d_reminder: true})

    {:ok, _} = Trygg.Push.subscribe(owner.user, subscription("owner-device"))
    {:ok, _} = Trygg.Push.subscribe(member, subscription("member-device"))

    %{owner: owner, child: child, member: member}
  end

  defp subscription(slug) do
    %{
      "endpoint" => "https://push.example.com/#{slug}",
      "keys" => %{"p256dh" => "BP#{slug}", "auth" => "auth-#{slug}"}
    }
  end

  defp log_feed(scope, child, vitamin_d?) do
    {:ok, entry} =
      Log.create_entry(scope, child, :feeding, %{
        "data" => %{"amount_ml" => "90", "vitamin_d" => vitamin_d?}
      })

    entry
  end

  test "notifies every caregiver after 18:00 when no drop was logged", ctx do
    assert run_scan(at(ctx.child, 18, 0)) == 1

    messages =
      for _ <- 1..2 do
        assert_received {:web_push, sub, message}
        {sub["endpoint"], Jason.decode!(message)}
      end

    assert messages |> Enum.map(&elem(&1, 0)) |> Enum.sort() == [
             "https://push.example.com/member-device",
             "https://push.example.com/owner-device"
           ]

    {_endpoint, payload} = hd(messages)
    assert payload["title"] =~ ctx.child.name
    assert payload["url"] == "/c/#{ctx.child.id}"
    refute_received {:web_push, _, _}
  end

  test "stays quiet before 18:00", ctx do
    assert run_scan(at(ctx.child, 17, 59)) == 0
    refute_received {:web_push, _, _}
  end

  test "stays quiet when a drop was already logged today", ctx do
    log_feed(ctx.owner, ctx.child, true)

    assert run_scan(at(ctx.child, 19, 0)) == 0
    refute_received {:web_push, _, _}
  end

  test "a feed without the drop doesn't count", ctx do
    log_feed(ctx.owner, ctx.child, false)

    assert run_scan(at(ctx.child, 19, 0)) == 1
  end

  test "sends at most once per local day", ctx do
    assert run_scan(at(ctx.child, 18, 0)) == 1
    assert run_scan(at(ctx.child, 18, 15)) == 0
    assert run_scan(at(ctx.child, 23, 0)) == 0

    assert_received {:web_push, _, _}
    assert_received {:web_push, _, _}
    refute_received {:web_push, _, _}
  end

  test "does nothing when the reminder is off", ctx do
    {:ok, _} = Families.update_child(ctx.owner, ctx.child, %{vitamin_d_reminder: false})

    assert run_scan(at(ctx.child, 19, 0)) == 0
    refute_received {:web_push, _, _}
  end

  test "viewers aren't notified", ctx do
    viewer = Trygg.AccountsFixtures.user_fixture()
    membership_fixture(ctx.child, viewer, :viewer)
    {:ok, _} = Trygg.Push.subscribe(viewer, subscription("viewer-device"))

    assert run_scan(at(ctx.child, 19, 0)) == 1

    endpoints =
      for _ <- 1..2 do
        assert_received {:web_push, sub, _message}
        sub["endpoint"]
      end

    refute "https://push.example.com/viewer-device" in endpoints
    refute_received {:web_push, _, _}
  end

  test "uses the child's own time zone for the deadline", ctx do
    {:ok, child} = Families.update_child(ctx.owner, ctx.child, %{timezone: "Asia/Tokyo"})

    # 18:30 in Tokyo is 09:30 UTC: past the deadline for this child only.
    now = fn _child -> DateTime.now!("Asia/Tokyo") |> Map.merge(%{hour: 18, minute: 30}) end
    assert run_scan(now) == 1
    assert Repo.reload!(child).vitamin_d_reminded_on == DateTime.to_date(now.(child))
  end

  test "skips a child who hasn't been born yet", ctx do
    Repo.update_all(Child,
      set: [birth_date: nil, expected_birth_date: Date.add(Date.utc_today(), 30)]
    )

    assert run_scan(at(ctx.child, 19, 0)) == 0
  end

  test "the worker runs the scan" do
    assert :ok = Trygg.Log.VitaminDReminderWorker.perform(%Oban.Job{})
  end
end
