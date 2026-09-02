defmodule Trygg.LogTest do
  use Trygg.DataCase, async: true

  alias Trygg.Log
  alias Trygg.Log.Entry

  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures
  import Trygg.LogFixtures

  setup do
    scope = user_scope_fixture()
    %{scope: scope, child: child_fixture(scope)}
  end

  describe "create_entry/4 validation" do
    test "a feed requires an amount and is instantaneous", %{scope: scope, child: child} do
      assert {:error, cs} =
               Log.create_entry(scope, child, :feeding, %{
                 "data" => %{"bottle_contents" => "formula"}
               })

      assert %{data: _} = errors_on(cs)

      assert {:ok, entry} =
               Log.create_entry(scope, child, :feeding, %{
                 "data" => %{"amount_ml" => "90", "bottle_contents" => "formula"}
               })

      assert entry.data["amount_ml"] == 90.0
      assert entry.data["bottle_contents"] == "formula"
      assert entry.ended_at == entry.started_at
      assert entry.logged_by_id == scope.user.id
      refute Entry.running?(entry)
    end

    test "diaper requires a kind", %{scope: scope, child: child} do
      assert {:error, _} = Log.create_entry(scope, child, :diaper, %{"data" => %{}})
      assert {:ok, e} = Log.create_entry(scope, child, :diaper, %{"data" => %{"kind" => "mixed"}})
      assert e.data == %{"kind" => "mixed"}
      assert e.ended_at == nil
    end

    test "rejects ended_at before started_at", %{scope: scope, child: child} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:error, cs} =
               Log.create_entry(scope, child, :sleep, %{
                 "started_at" => now,
                 "ended_at" => DateTime.add(now, -60, :second),
                 "data" => %{}
               })

      assert %{ended_at: _} = errors_on(cs)
    end
  end

  describe "authorization" do
    test "viewers cannot write, can read", %{child: child} do
      viewer_user = user_fixture()
      membership_fixture(child, viewer_user, :viewer)
      viewer = user_scope_fixture(viewer_user)

      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        Log.create_entry(viewer, child, :diaper, %{"data" => %{"kind" => "wet"}})
      end

      assert Log.recent_entries(viewer, child) == []
    end
  end

  describe "timers" do
    test "start_timer is idempotent per type", %{scope: scope, child: child} do
      assert {:ok, %Entry{ended_at: nil} = t1} = Log.start_timer(scope, child, :sleep)
      assert {:ok, t2} = Log.start_timer(scope, child, :sleep)
      assert t1.id == t2.id
      assert [running] = Log.running_timers(scope, child)
      assert running.id == t1.id
    end

    test "stop_timer sets ended_at and merges data", %{scope: scope, child: child} do
      {:ok, timer} = Log.start_timer(scope, child, :sleep, %{"data" => %{"location" => "crib"}})

      assert {:ok, stopped} = Log.stop_timer(scope, timer, %{"note" => "woke happy"})
      assert stopped.ended_at
      assert stopped.data["location"] == "crib"
      assert stopped.note == "woke happy"
      assert Log.running_timers(scope, child) == []
    end

    test "start_timer accepts a past start time", %{scope: scope, child: child} do
      past = DateTime.utc_now() |> DateTime.add(-40, :minute) |> DateTime.truncate(:second)
      assert {:ok, nap} = Log.start_timer(scope, child, :sleep, %{"started_at" => past})
      assert nap.started_at == past
      assert nap.ended_at == nil
    end

    test "retime_entry moves timing without touching type-specific data", %{
      scope: scope,
      child: child
    } do
      {:ok, nap} = Log.start_timer(scope, child, :sleep, %{"data" => %{"location" => "crib"}})
      earlier = DateTime.add(nap.started_at, -20 * 60, :second)

      assert {:ok, moved} = Log.retime_entry(scope, nap, %{"started_at" => earlier})
      assert moved.started_at == earlier
      assert moved.ended_at == nil
      assert moved.data["location"] == "crib"
    end

    test "retime_entry rejects an end before the start", %{scope: scope, child: child} do
      {:ok, nap} = Log.start_timer(scope, child, :sleep)
      before = DateTime.add(nap.started_at, -60, :second)

      assert {:error, changeset} = Log.retime_entry(scope, nap, %{"ended_at" => before})
      assert %{ended_at: _} = errors_on(changeset)
    end
  end

  describe "summary/2" do
    test "counts today's events and total sleep in the child's day", %{scope: scope, child: child} do
      entry_fixture(scope, child, type: :feeding)
      entry_fixture(scope, child, type: :feeding)
      entry_fixture(scope, child, type: :diaper)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        Log.create_entry(scope, child, :sleep, %{
          "started_at" => DateTime.add(now, -3600, :second),
          "ended_at" => now,
          "data" => %{}
        })

      summary = Log.summary(scope, child)
      assert summary.today.feedings == 2
      assert summary.today.diapers == 1
      assert summary.today.sleep_seconds >= 3600
      assert summary.last_feeding.type == :feeding
    end

    test "counts an in-progress sleep up to now", %{scope: scope, child: child} do
      {:ok, _} =
        Log.create_entry(scope, child, :sleep, %{
          "started_at" =>
            DateTime.add(DateTime.utc_now(), -600, :second) |> DateTime.truncate(:second),
          "data" => %{}
        })

      summary = Log.summary(scope, child)
      assert summary.today.sleep_seconds >= 590
      assert [%Entry{type: :sleep}] = summary.running
    end
  end

  describe "realtime" do
    test "writes broadcast on the child's topic", %{scope: scope, child: child} do
      Trygg.Families.subscribe(child.id)

      {:ok, entry} = Log.create_entry(scope, child, :diaper, %{"data" => %{"kind" => "wet"}})
      assert_receive {:log, :created, %Entry{id: id}}
      assert id == entry.id

      {:ok, _} =
        Log.update_entry(scope, entry, %{
          "type" => "diaper",
          "started_at" => entry.started_at,
          "data" => %{"kind" => "dirty"}
        })

      assert_receive {:log, :updated, %Entry{}}

      {:ok, _} = Log.delete_entry(scope, entry)
      assert_receive {:log, :deleted, %Entry{}}
    end
  end
end
