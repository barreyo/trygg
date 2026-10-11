defmodule Trygg.Sleep.NapConventionsTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias Trygg.Sleep.NapConventions

  @child %Child{timezone: "Etc/UTC"}

  defp at(date, hour, minute \\ 0),
    do: DateTime.new!(date, Time.new!(hour, minute, 0), "Etc/UTC")

  defp sleep(date, hour, minutes, location) do
    start = at(date, hour)
    data = if location, do: %{"location" => location}, else: %{}

    %Entry{
      type: :sleep,
      started_at: start,
      ended_at: DateTime.add(start, minutes * 60),
      data: data
    }
  end

  @today ~D[2026-10-11]

  defp assess(entries, min \\ 120),
    do:
      NapConventions.assess(%{
        child: @child,
        entries: entries,
        today: @today,
        min_window_minutes: min
      })

  test "the four conventions" do
    assert Enum.map(NapConventions.conventions(), & &1.id) ==
             [:soothing, :consistency, :timing, :independent]
  end

  describe "assess/1: place" do
    test "needs five daytime sleeps with somewhere noted" do
      assert %{place: nil} = assess([sleep(~D[2026-10-10], 9, 60, "crib")])
    end

    test "80% in one place is on target" do
      naps = for h <- 8..12, do: sleep(~D[2026-10-10], h, 45, "crib")
      naps = naps ++ [sleep(~D[2026-10-10], 14, 20, "stroller")]
      assessed = assess(naps)

      assert %{where: "crib", count: 6, ok?: true} = assessed.place
      assert_in_delta assessed.place.share, 5 / 6, 0.001
    end

    test "scattered naps are not" do
      places = ~w(crib stroller contact crib bassinet)
      naps = for {p, h} <- Enum.zip(places, 8..12), do: sleep(~D[2026-10-10], h, 45, p)
      refute assess(naps).place.ok?
    end

    test "the night's sleep isn't a nap" do
      naps = for h <- 8..11, do: sleep(~D[2026-10-10], h, 45, "crib")
      night = sleep(~D[2026-10-10], 19, 600, "bassinet")
      assert %{place: nil} = assess([night | naps])
    end

    test "running sleeps don't count" do
      running = %{sleep(~D[2026-10-10], 9, 60, "crib") | ended_at: nil}
      assert %{place: nil} = assess(List.duplicate(running, 6))
    end
  end

  describe "assess/1: time awake before bed" do
    # A 45-minute nap ending at the given time, then the night's sleep from `bed_hour`.
    defp evening(date, nap_end_hour, nap_end_minute, bed_hour) do
      ended = at(date, nap_end_hour, nap_end_minute)

      nap = %Entry{
        type: :sleep,
        started_at: DateTime.add(ended, -45 * 60),
        ended_at: ended,
        data: %{"location" => "crib"}
      }

      [nap, sleep(date, bed_hour, 600, "crib")]
    end

    test "counts the evenings the last nap ended too close to the night's sleep" do
      # Nap ends 17:15, night at 19:00: 105 minutes, under the 120 asked for.
      short =
        for d <- [~D[2026-10-10], ~D[2026-10-09], ~D[2026-10-08]], do: evening(d, 17, 15, 19)

      ok = evening(~D[2026-10-07], 15, 30, 19)

      assert %{catnaps: %{days: 3, ok?: false}} = assess(List.flatten([ok | short]))
    end

    test "is fine when there was time, and one short evening isn't a pattern" do
      assert %{catnaps: %{days: 0, ok?: true}} = assess(evening(~D[2026-10-10], 15, 30, 19))
      assert %{catnaps: %{days: 1, ok?: true}} = assess(evening(~D[2026-10-10], 17, 30, 19))
    end

    test "only the last seven evenings count" do
      assert %{catnaps: %{days: 0}} = assess(evening(~D[2026-10-01], 17, 30, 19))
    end

    test "is skipped without a minimum or a date" do
      entries = evening(~D[2026-10-10], 17, 30, 19)
      assert %{catnaps: %{days: 0, ok?: true}} = assess(entries, nil)

      assert %{catnaps: %{days: 0}} =
               NapConventions.assess(%{child: @child, entries: entries, min_window_minutes: 120})
    end

    test "a short sleep in the evening is not the night's sleep" do
      nap = sleep(~D[2026-10-10], 14, 45, "crib")
      catnap = sleep(~D[2026-10-10], 17, 30, "crib")
      assert %{catnaps: %{days: 0}} = assess([nap, catnap])
    end
  end

  test "drop_for/1 follows the age" do
    assert NapConventions.drop_for(100).label == "3–6 months"
    assert NapConventions.drop_for(300).label == "6–12 months"
    assert NapConventions.drop_for(400).label == "12–18 months"
    assert NapConventions.drop_for(50) == nil
    assert NapConventions.drop_for(nil) == nil
  end

  test "there are ways to stretch short naps and signs of a nap going" do
    assert Enum.map(NapConventions.short_nap_fixes(), & &1.id) == [:disrupt, :bore]
    assert length(NapConventions.drop_signs()) > 0
    assert length(NapConventions.transition_tips()) > 0
  end
end
