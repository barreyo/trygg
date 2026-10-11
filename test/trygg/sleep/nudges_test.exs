defmodule Trygg.Sleep.NudgesTest do
  # async: false — flips `config :trygg, Trygg.Push` (process-global) and uses
  # the shared recording sender.
  use Trygg.DataCase, async: false

  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.Families
  alias Trygg.Families.Child
  alias Trygg.Log
  alias Trygg.Reports.Day
  alias Trygg.Repo
  alias Trygg.Sleep.Nudges

  defp run_scan, do: Oban.Testing.with_testing_mode(:inline, fn -> Nudges.run() end)

  describe "candidates/1" do
    @date ~D[2026-10-10]
    @child %Child{
      name: "Astrid",
      timezone: "Etc/UTC",
      day_start: ~T[08:00:00],
      night_start: ~T[20:00:00]
    }

    defp t(hour, minute \\ 0), do: DateTime.new!(@date, Time.new!(hour, minute, 0), "Etc/UTC")

    defp ctx(attrs \\ []) do
      now = attrs[:now] || t(12)

      %{
        child: @child,
        now: now,
        phase: %{id: :newborn, age_days: 28},
        prediction: %{state: :awake, anchor_ts: t(10, 30), bedtime: nil},
        today: Day.build(@child, @date, [], now),
        insights: [],
        last_feed_at: nil
      }
      |> Map.merge(Map.new(attrs))
    end

    defp kinds(ctx), do: ctx |> Nudges.candidates() |> Enum.map(& &1.kind)

    test "a nap window that's open nudges once per wake-up" do
      ctx = ctx(insights: [%{id: "nap-window", detail: "Awake 1h 30m."}])

      assert [%{kind: :nap_window, key: key, title: title, body: "Awake 1h 30m."}] =
               Nudges.candidates(ctx)

      assert key == "nap-window:#{DateTime.to_unix(t(10, 30))}"
      assert title =~ "Astrid"

      # A later wake-up is a different key.
      later = put_in(ctx.prediction.anchor_ts, t(13))
      assert [%{key: other}] = Nudges.candidates(%{later | now: t(14)})
      refute other == key
    end

    test "nap and feed nudges are daytime only" do
      night = t(3)

      assert kinds(
               ctx(
                 now: night,
                 last_feed_at: t(0),
                 insights: [%{id: "nap-window", detail: "x"}, %{id: "feed-due", detail: "y"}]
               )
             ) == []
    end

    test "a feed that may be due nudges once per last feed" do
      ctx = ctx(last_feed_at: t(8, 30), insights: [%{id: "feed-due", detail: "It's been 3h."}])

      assert [%{kind: :feed_due, key: key, title: title}] = Nudges.candidates(ctx)
      assert key == "feed-due:#{DateTime.to_unix(t(8, 30))}"
      assert title =~ "feed"
    end

    test "nothing when there are no insights to act on" do
      assert kinds(ctx()) == []
    end

    test "the bedtime routine starts 30 minutes before the estimated bedtime, from 8 weeks" do
      bed = %{at: t(19, 40), label: "19:40"}

      ctx =
        ctx(
          now: t(19, 15),
          phase: %{id: :newborn, age_days: 60},
          prediction: %{state: :awake, anchor_ts: t(17), bedtime: bed}
        )

      assert [%{kind: :bedtime_routine, key: "bedtime:2026-10-10", body: body}] =
               Nudges.candidates(ctx)

      assert body =~ "19:40"

      # Too early, already past, younger than 8 weeks, asleep, or bedtime already started.
      assert kinds(%{ctx | now: t(18, 59)}) == []
      assert kinds(%{ctx | now: t(19, 41)}) == []
      assert kinds(%{ctx | phase: %{id: :newborn, age_days: 40}}) == []
      assert kinds(put_in(ctx.prediction.state, :asleep)) == []

      started = %{ctx.today | bedtime: t(19, 5)}
      assert kinds(%{ctx | today: started}) == []
    end

    test "the bedtime routine nudge can fall after nightfall" do
      # Bedtime 20:15 is after night_start, so 19:50 is daytime and 20:05 is not.
      ctx =
        ctx(
          now: t(20, 5),
          phase: %{id: :foundations, age_days: 100},
          prediction: %{
            state: :awake,
            anchor_ts: t(18),
            bedtime: %{at: t(20, 15), label: "20:15"}
          }
        )

      assert kinds(ctx) == [:bedtime_routine]
    end
  end

  describe "run/1" do
    setup do
      Trygg.Push.Sender.Test.listen()
      prev = Application.get_env(:trygg, Trygg.Push)
      Application.put_env(:trygg, Trygg.Push, Keyword.put(prev, :enabled, true))
      on_exit(fn -> Application.put_env(:trygg, Trygg.Push, prev) end)

      %{owner_scope: owner, member: member} = shared = shared_child_fixture(:caregiver)

      # A child whose local time is about noon right now (a fixed-offset zone, so
      # no DST), with five regular days behind them, this morning's wake-up and
      # a nap that ended 90 minutes ago: inside their usual nap window.
      offset = rem(12 - DateTime.utc_now().hour + 24, 24)
      offset = if offset > 12, do: offset - 24, else: offset

      zone =
        cond do
          offset == 0 -> "Etc/UTC"
          offset > 0 -> "Etc/GMT-#{offset}"
          true -> "Etc/GMT+#{-offset}"
        end

      {:ok, child} =
        Families.update_child(owner, shared.child, %{timezone: zone, sleep_nudges: true})

      today = Child.local_today(child)
      local = &Child.at_local(child, &1, &2)

      sleep = fn date, from, to, end_date ->
        {:ok, _} =
          Log.create_entry(owner, child, :sleep, %{
            "started_at" => local.(date, from),
            "ended_at" => local.(end_date, to)
          })
      end

      for back <- 5..1//-1 do
        date = Date.add(today, -back)
        sleep.(date, ~T[20:00:00], ~T[07:00:00], Date.add(date, 1))
        sleep.(date, ~T[09:30:00], ~T[10:30:00], date)
        sleep.(date, ~T[12:30:00], ~T[13:30:00], date)
        sleep.(date, ~T[15:30:00], ~T[16:30:00], date)
      end

      sleep.(Date.add(today, -1), ~T[20:00:00], ~T[07:00:00], today)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        Log.create_entry(owner, child, :sleep, %{
          "started_at" => DateTime.add(now, -150 * 60, :second),
          "ended_at" => DateTime.add(now, -90 * 60, :second)
        })

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

    test "sends the nap window nudge to every caregiver, once", ctx do
      assert run_scan() == 1

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
      assert payload["title"] =~ "nap window"
      assert payload["url"] == "/c/#{ctx.child.id}/sleep"

      # The same wake-up isn't nudged again.
      assert run_scan() == 0
      refute_received {:web_push, _, _}
    end

    test "does nothing while the nudges are off", ctx do
      {:ok, _} = Families.update_child(ctx.owner, ctx.child, %{sleep_nudges: false})

      assert run_scan() == 0
      refute_received {:web_push, _, _}
    end

    test "viewers aren't notified", ctx do
      viewer = user_fixture()
      membership_fixture(ctx.child, viewer, :viewer)
      {:ok, _} = Trygg.Push.subscribe(viewer, subscription("viewer-device"))

      assert run_scan() == 1

      endpoints =
        for _ <- 1..2 do
          assert_received {:web_push, sub, _message}
          sub["endpoint"]
        end

      refute "https://push.example.com/viewer-device" in endpoints
      refute_received {:web_push, _, _}
    end

    test "skips a child who hasn't been born yet, or isn't tracking sleep", _ctx do
      Repo.update_all(Child,
        set: [birth_date: nil, expected_birth_date: Date.add(Date.utc_today(), 30)]
      )

      assert run_scan() == 0

      Repo.update_all(Child,
        set: [birth_date: Date.add(Date.utc_today(), -20), tracked_types: [:diaper]]
      )

      assert run_scan() == 0
      refute_received {:web_push, _, _}
    end

    test "old claims are pruned", ctx do
      old = DateTime.add(DateTime.utc_now(), -8 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.insert_all("sleep_nudge_claims", [
        %{child_id: ctx.child.id, key: "ancient", inserted_at: old}
      ])

      assert run_scan() == 1

      keys = Repo.all(from(c in "sleep_nudge_claims", select: c.key))
      refute "ancient" in keys
    end
  end
end
