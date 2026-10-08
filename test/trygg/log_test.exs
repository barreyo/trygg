defmodule Trygg.LogTest do
  use Trygg.DataCase, async: true

  alias Trygg.Families.Child
  alias Trygg.Log
  alias Trygg.Log.Entry

  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures
  import Trygg.LogFixtures

  setup do
    scope = user_scope_fixture()
    %{scope: scope, child: child_fixture(scope)}
  end

  describe "list_entries/3 filtering and paging" do
    test ":data matches the entry's data fields", %{scope: scope, child: child} do
      entry_fixture(scope, child, %{:type => :diaper, "data" => %{"kind" => "pee"}})
      poo = entry_fixture(scope, child, %{:type => :diaper, "data" => %{"kind" => "poo"}})

      assert [found] = Log.list_entries(scope, child, type: :diaper, data: %{"kind" => "poo"})
      assert found.id == poo.id
    end

    test ":data can match vitamin D on a feed", %{scope: scope, child: child} do
      {:ok, plain} = feed(scope, child, %{})
      {:ok, with_drop} = feed(scope, child, %{"vitamin_d" => "true"})

      assert [found] = Log.list_entries(scope, child, data: %{"vitamin_d" => "true"})
      assert found.id == with_drop.id
      refute found.id == plain.id
    end

    test ":before continues from a cursor, including entries sharing a timestamp", %{
      scope: scope,
      child: child
    } do
      at = ~U[2026-09-01 10:00:00Z]

      ids =
        for _ <- 1..5 do
          entry_fixture(scope, child, %{"started_at" => at}).id
        end

      newest_first = Enum.reverse(ids)
      [first, second] = Log.list_entries(scope, child, limit: 2)
      assert [first.id, second.id] == Enum.take(newest_first, 2)

      rest = Log.list_entries(scope, child, before: {second.started_at, second.id})
      assert Enum.map(rest, & &1.id) == Enum.drop(newest_first, 2)
    end
  end

  describe "vitamin D on a feed" do
    defp feed(scope, child, data, attrs \\ %{}) do
      Log.create_entry(
        scope,
        child,
        :feeding,
        Map.merge(%{"data" => Map.put(data, "amount_ml", "90")}, attrs)
      )
    end

    test "is stored only when ticked", %{scope: scope, child: child} do
      {:ok, given} = feed(scope, child, %{"vitamin_d" => "true"})
      {:ok, unticked} = feed(scope, child, %{"vitamin_d" => "false"})
      {:ok, absent} = feed(scope, child, %{})

      assert given.data["vitamin_d"] == true
      assert Entry.vitamin_d?(given)
      refute Map.has_key?(unticked.data, "vitamin_d")
      refute Map.has_key?(absent.data, "vitamin_d")
      refute Entry.vitamin_d?(absent)
    end

    test "only feeds can carry it", %{scope: scope, child: child} do
      {:ok, diaper} =
        Log.create_entry(scope, child, :diaper, %{
          "data" => %{"kind" => "pee", "vitamin_d" => true}
        })

      refute Map.has_key?(diaper.data, "vitamin_d")
      refute Entry.vitamin_d?(diaper)
    end

    test "summary and vitamin_d_given?/2 look at the child's local day", %{
      scope: scope,
      child: child
    } do
      today = Child.local_today(child)
      refute Log.summary(scope, child).vitamin_d_given_today?

      yesterday = DateTime.add(DateTime.utc_now(), -2 * 86_400, :second)
      {:ok, _} = feed(scope, child, %{"vitamin_d" => true}, %{"started_at" => yesterday})
      refute Log.summary(scope, child).vitamin_d_given_today?
      refute Log.vitamin_d_given?(child, today)

      {:ok, entry} = feed(scope, child, %{"vitamin_d" => true})
      assert Log.summary(scope, child).vitamin_d_given_today?
      assert Log.vitamin_d_given?(child, today)

      {:ok, _} = Log.delete_entry(scope, entry)
      refute Log.summary(scope, child).vitamin_d_given_today?
    end
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

    test "an entry logged on an API token is credited to the integration, not a person", %{
      scope: scope,
      child: child
    } do
      {:ok, token} =
        Trygg.ApiTokens.create_token(scope, child.family_id, %{
          name: "Home Assistant",
          role: :caregiver
        })

      {:ok, api_scope} = Trygg.ApiTokens.authenticate(token.secret)
      diaper = %{"data" => %{"kind" => "pee"}}

      {:ok, created} = Log.create_entry(api_scope, child, :diaper, diaper)
      {:ok, timer} = Log.start_timer(api_scope, child, :sleep)

      {:ok, synced} =
        Log.sync_entry(api_scope, child, %{
          "client_id" => Ecto.UUID.generate(),
          "type" => "diaper",
          "started_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "data" => diaper["data"]
        })

      for entry <- [created, timer, synced] do
        assert entry.logged_by_id == nil
        assert entry.logged_via == "Home Assistant"
        assert Entry.logged_by_integration?(entry)
      end

      # A person's own entries are unaffected.
      {:ok, mine} = Log.create_entry(scope, child, :diaper, diaper)
      assert mine.logged_by_id == scope.user.id
      assert mine.logged_via == nil
      refute Entry.logged_by_integration?(mine)
    end

    test "the credit survives the token being revoked", %{scope: scope, child: child} do
      {:ok, token} =
        Trygg.ApiTokens.create_token(scope, child.family_id, %{name: "Bridge", role: :caregiver})

      {:ok, api_scope} = Trygg.ApiTokens.authenticate(token.secret)
      {:ok, entry} = Log.create_entry(api_scope, child, :diaper, %{"data" => %{"kind" => "pee"}})

      {:ok, _} = Trygg.ApiTokens.revoke_token(scope, token)

      assert Log.get_entry!(scope, entry.id).logged_via == "Bridge"
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
        Log.create_entry(viewer, child, :diaper, %{"data" => %{"kind" => "pee"}})
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
      entry_fixture(scope, child, %{"data" => %{"kind" => "poo"}, :type => :diaper})
      entry_fixture(scope, child, %{"data" => %{"kind" => "mixed"}, :type => :diaper})

      # Anchor the nap to the start of the child's day so it lies wholly inside
      # today even when the test runs just after local midnight.
      {day_start, _day_end} = Child.day_bounds(child)

      {:ok, _} =
        Log.create_entry(scope, child, :sleep, %{
          "started_at" => day_start,
          "ended_at" => DateTime.add(day_start, 3600, :second),
          "data" => %{}
        })

      summary = Log.summary(scope, child)
      assert summary.today.feedings == 2
      assert summary.today.volume_ml == 180.0
      assert summary.today.diapers == 3
      assert summary.today.diapers_wet == 2
      assert summary.today.diapers_dirty == 2
      assert summary.today.sleep_seconds == 3600
      assert summary.last_feeding.type == :feeding
    end

    test "counts an in-progress sleep up to now", %{scope: scope, child: child} do
      # One clock read; clamp to the start of the child's day so only today's
      # part of the nap is expected just after local midnight.
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {day_start, _day_end} = Child.day_bounds(child)
      started_at = Enum.max([DateTime.add(now, -600, :second), day_start], DateTime)

      {:ok, _} =
        Log.create_entry(scope, child, :sleep, %{"started_at" => started_at, "data" => %{}})

      summary = Log.summary(scope, child)
      assert summary.today.sleep_seconds >= DateTime.diff(now, started_at, :second)
      assert [%Entry{type: :sleep}] = summary.running
    end
  end

  describe "photos" do
    test "store_photo persists bytes and returns attrs to attach", %{scope: scope, child: child} do
      assert {:ok, attrs} = Log.store_photo(child, tiny_png(), "image/png")
      assert attrs["photo_content_type"] == "image/png"
      assert attrs["photo_key"] =~ ~r"^children/#{child.id}/log/.+\.png$"

      {:ok, entry} =
        Log.create_entry(scope, child, :diaper, Map.merge(%{"data" => %{"kind" => "pee"}}, attrs))

      assert entry.photo_key == attrs["photo_key"]
      assert {:ok, bytes, "image/png"} = Log.fetch_photo(entry)
      assert bytes == tiny_png()
    end

    test "store_photo rejects a non-image", %{child: child} do
      assert {:error, :unsupported_type} = Log.store_photo(child, "not-an-image", "text/plain")
    end

    test "store_photo rejects an oversized file", %{child: child} do
      big = :binary.copy("x", Log.max_photo_bytes() + 1)
      assert {:error, :too_large} = Log.store_photo(child, big, "image/png")
    end

    test "fetch_photo returns :error when the entry has none", %{scope: scope, child: child} do
      {:ok, entry} = Log.create_entry(scope, child, :diaper, %{"data" => %{"kind" => "pee"}})
      assert :error = Log.fetch_photo(entry)
    end

    test "update_entry replacing the photo discards the old bytes", %{scope: scope, child: child} do
      {:ok, first} = Log.store_photo(child, tiny_png(), "image/png")

      {:ok, entry} =
        Log.create_entry(scope, child, :diaper, Map.merge(%{"data" => %{"kind" => "pee"}}, first))

      {:ok, second} = Log.store_photo(child, tiny_png(), "image/jpeg")

      {:ok, updated} =
        Log.update_entry(scope, entry, %{
          "type" => "diaper",
          "started_at" => entry.started_at,
          "data" => %{"kind" => "pee"},
          "photo_key" => second["photo_key"],
          "photo_content_type" => "image/jpeg"
        })

      assert updated.photo_key == second["photo_key"]
      assert {:error, _} = Trygg.Storage.get(first["photo_key"])
      assert {:ok, _} = Trygg.Storage.get(second["photo_key"])
    end

    test "update_entry clearing photo_key removes the stored bytes", %{scope: scope, child: child} do
      {:ok, attrs} = Log.store_photo(child, tiny_png(), "image/png")

      {:ok, entry} =
        Log.create_entry(scope, child, :diaper, Map.merge(%{"data" => %{"kind" => "pee"}}, attrs))

      {:ok, updated} =
        Log.update_entry(scope, entry, %{
          "type" => "diaper",
          "started_at" => entry.started_at,
          "data" => %{"kind" => "pee"},
          "photo_key" => nil
        })

      refute Entry.has_photo?(updated)
      assert {:error, _} = Trygg.Storage.get(attrs["photo_key"])
    end

    test "delete_entry removes the photo too", %{scope: scope, child: child} do
      {:ok, attrs} = Log.store_photo(child, tiny_png(), "image/png")

      {:ok, entry} =
        Log.create_entry(scope, child, :diaper, Map.merge(%{"data" => %{"kind" => "pee"}}, attrs))

      {:ok, _} = Log.delete_entry(scope, entry)
      assert {:error, _} = Trygg.Storage.get(attrs["photo_key"])
    end

    test "changeset rejects an unsupported photo content type", %{scope: scope, child: child} do
      assert {:error, cs} =
               Log.create_entry(
                 scope,
                 child,
                 :diaper,
                 %{
                   "data" => %{"kind" => "pee"},
                   "photo_key" => "children/#{child.id}/log/x.tiff",
                   "photo_content_type" => "image/tiff"
                 }
               )

      assert %{photo_content_type: _} = errors_on(cs)
    end
  end

  describe "realtime" do
    test "writes broadcast on the child's topic", %{scope: scope, child: child} do
      Trygg.Families.subscribe(child.id)

      {:ok, entry} = Log.create_entry(scope, child, :diaper, %{"data" => %{"kind" => "pee"}})
      assert_receive {:log, :created, %Entry{id: id}}
      assert id == entry.id

      {:ok, _} =
        Log.update_entry(scope, entry, %{
          "type" => "diaper",
          "started_at" => entry.started_at,
          "data" => %{"kind" => "poo"}
        })

      assert_receive {:log, :updated, %Entry{}}

      {:ok, _} = Log.delete_entry(scope, entry)
      assert_receive {:log, :deleted, %Entry{}}
    end
  end

  defp offline_diaper(cid, overrides \\ %{}) do
    Map.merge(
      %{
        "client_id" => cid,
        "type" => "diaper",
        "started_at" =>
          DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.to_iso8601(),
        "data" => %{"kind" => "pee"}
      },
      overrides
    )
  end

  describe "sync_entry/3" do
    setup do
      %{cid: Ecto.UUID.generate()}
    end

    test "records an offline entry with its client_id and event time", %{
      scope: scope,
      child: child,
      cid: cid
    } do
      assert {:ok, entry} = Log.sync_entry(scope, child, offline_diaper(cid))
      assert entry.client_id == cid
      assert entry.type == :diaper
      assert entry.data == %{"kind" => "pee"}
      assert entry.logged_by_id == scope.user.id
      assert DateTime.diff(DateTime.utc_now(), entry.started_at) in 280..320
    end

    test "re-syncing the same client_id updates in place, not a duplicate", %{
      scope: scope,
      child: child,
      cid: cid
    } do
      assert {:ok, first} = Log.sync_entry(scope, child, offline_diaper(cid))

      assert {:ok, second} =
               Log.sync_entry(scope, child, offline_diaper(cid, %{"note" => "leaked"}))

      assert second.id == first.id
      assert second.note == "leaked"
      assert Log.recent_entries(scope, child) |> length() == 1
    end

    test "first sync broadcasts :created, a re-sync broadcasts :updated", %{
      scope: scope,
      child: child,
      cid: cid
    } do
      Trygg.Families.subscribe(child.id)

      {:ok, _} = Log.sync_entry(scope, child, offline_diaper(cid))
      assert_receive {:log, :created, %Entry{client_id: ^cid}}

      {:ok, _} = Log.sync_entry(scope, child, offline_diaper(cid, %{"note" => "again"}))
      assert_receive {:log, :updated, %Entry{client_id: ^cid}}
    end

    test "clamps a future started_at back to now", %{scope: scope, child: child, cid: cid} do
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

      assert {:ok, entry} =
               Log.sync_entry(scope, child, offline_diaper(cid, %{"started_at" => future}))

      assert DateTime.diff(DateTime.utc_now(), entry.started_at) |> abs() <= 5
    end

    test "a missing or malformed client_id is rejected", %{scope: scope, child: child, cid: cid} do
      assert {:error, :missing_client_id} =
               Log.sync_entry(scope, child, offline_diaper(cid) |> Map.delete("client_id"))

      assert {:error, :missing_client_id} =
               Log.sync_entry(scope, child, offline_diaper("not-a-uuid"))
    end

    test "invalid type-specific data comes back as a changeset error", %{
      scope: scope,
      child: child,
      cid: cid
    } do
      attrs =
        offline_diaper(cid, %{"type" => "feeding", "data" => %{"bottle_contents" => "formula"}})

      assert {:error, %Ecto.Changeset{} = cs} = Log.sync_entry(scope, child, attrs)
      assert %{data: _} = errors_on(cs)
    end

    test "an offline feed with a null ended_at is stored as instantaneous", %{
      scope: scope,
      child: child,
      cid: cid
    } do
      attrs =
        offline_diaper(cid, %{
          "type" => "feeding",
          "ended_at" => nil,
          "data" => %{"amount_ml" => 90}
        })

      assert {:ok, entry} = Log.sync_entry(scope, child, attrs)
      assert entry.ended_at == entry.started_at
    end

    test "syncs a sleep that started and ended offline as one entry", %{
      scope: scope,
      child: child,
      cid: cid
    } do
      started = DateTime.utc_now() |> DateTime.add(-7200, :second)
      ended = DateTime.utc_now() |> DateTime.add(-3600, :second)

      running =
        offline_diaper(cid, %{
          "type" => "sleep",
          "started_at" => DateTime.to_iso8601(started),
          "data" => %{"location" => "crib"}
        })

      assert {:ok, open} = Log.sync_entry(scope, child, running)
      assert open.ended_at == nil

      assert {:ok, closed} =
               Log.sync_entry(
                 scope,
                 child,
                 Map.put(running, "ended_at", DateTime.to_iso8601(ended))
               )

      assert closed.id == open.id
      assert DateTime.diff(closed.ended_at, closed.started_at) == 3600
    end

    test "a viewer cannot sync", %{child: child, cid: cid} do
      viewer_user = user_fixture()
      membership_fixture(child, viewer_user, :viewer)
      viewer = user_scope_fixture(viewer_user)

      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        Log.sync_entry(viewer, child, offline_diaper(cid))
      end
    end

    test "collapses two overlapping open sleeps into the earliest, merging notes", %{
      scope: scope,
      child: child,
      cid: cid
    } do
      earlier = DateTime.utc_now() |> DateTime.add(-1800, :second)
      later = DateTime.utc_now() |> DateTime.add(-600, :second)

      # One started online (no client_id), then a second synced from offline.
      {:ok, online} = Log.start_timer(scope, child, :sleep, %{"started_at" => earlier})

      {:ok, synced} =
        Log.sync_entry(
          scope,
          child,
          offline_diaper(cid, %{
            "type" => "sleep",
            "started_at" => DateTime.to_iso8601(later),
            "ended_at" => nil,
            "note" => "contact nap",
            "data" => %{}
          })
        )

      # The earliest-started open sleep survives and keeps the note; the
      # offline-synced duplicate is gone and only one open sleep remains.
      assert synced.id == online.id
      assert synced.note == "contact nap"
      assert synced.ended_at == nil
      assert [remaining] = Log.running_timers(scope, child)
      assert remaining.id == online.id
      refute Enum.any?(Log.list_entries(scope, child), &(&1.client_id == cid))
    end
  end

  describe "sync_stop_timer/4" do
    test "stops a running timer by its server id", %{scope: scope, child: child} do
      {:ok, nap} = Log.start_timer(scope, child, :sleep)
      at = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, stopped} =
               Log.sync_stop_timer(scope, child, nap.id, DateTime.to_iso8601(at))

      assert stopped.id == nap.id
      assert stopped.ended_at == at
      assert Log.running_timers(scope, child) == []
    end

    test "is idempotent", %{scope: scope, child: child} do
      started = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      {:ok, nap} = Log.start_timer(scope, child, :sleep, %{"started_at" => started})
      at = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:second)
      iso = DateTime.to_iso8601(at)

      assert {:ok, _} = Log.sync_stop_timer(scope, child, nap.id, iso)
      assert {:ok, again} = Log.sync_stop_timer(scope, child, nap.id, iso)
      assert again.ended_at == at
    end

    test "not_found for an entry on another child or a bad id", %{scope: scope, child: child} do
      other = child_fixture(scope)
      {:ok, elsewhere} = Log.start_timer(scope, other, :sleep)

      assert {:error, :not_found} = Log.sync_stop_timer(scope, child, elsewhere.id, nil)
      assert {:error, :not_found} = Log.sync_stop_timer(scope, child, 999_999, nil)
      assert {:error, :not_found} = Log.sync_stop_timer(scope, child, "not-an-id", nil)
    end
  end
end
