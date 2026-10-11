defmodule Trygg.Reports.PlanNightsTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Reports.PlanNights
  alias Trygg.Sleep.{Checkins, NightWake, Plan}

  @child %Child{timezone: "Etc/UTC"}
  @plan %Plan{started_on: ~D[2026-10-10], notes: %{"2" => "Two long cries"}}

  defp at(date, hour, minute \\ 0), do: DateTime.new!(date, Time.new!(hour, minute, 0), "Etc/UTC")
  defp ev(kind, dt), do: Checkins.event(kind, dt)

  defp bedtime_wake(date, minute_to_sleep) do
    start = at(date, 19, 30)

    %NightWake{
      kind: :bedtime,
      started_at: start,
      ended_at: DateTime.add(start, minute_to_sleep * 60, :second),
      events: [
        ev("cry", start),
        ev("pop_in", DateTime.add(start, 300, :second)),
        ev("asleep", DateTime.add(start, minute_to_sleep * 60, :second))
      ],
      cry_seconds: minute_to_sleep * 60
    }
  end

  defp waking(date, hour, minutes_crying) do
    start = at(date, hour)

    %NightWake{
      kind: :waking,
      started_at: start,
      ended_at: DateTime.add(start, minutes_crying * 60, :second),
      events: [
        ev("cry", start),
        ev("pop_in", DateTime.add(start, 300, :second)),
        ev("pop_in", DateTime.add(start, 900, :second)),
        ev("asleep", DateTime.add(start, minutes_crying * 60, :second))
      ],
      cry_seconds: minutes_crying * 60
    }
  end

  defp nights(list), do: %{nights: list}

  test "one entry per night from night 1 to the current night" do
    now = at(~D[2026-10-12], 21)
    result = PlanNights.build(@child, @plan, [], nights([]), now)

    assert Enum.map(result, & &1.number) == [1, 2, 3]
    assert Enum.map(result, & &1.date) == [~D[2026-10-10], ~D[2026-10-11], ~D[2026-10-12]]
  end

  test "before night 1 there's nothing, and it stops at 14 nights" do
    assert PlanNights.build(@child, @plan, [], nights([]), at(~D[2026-10-10], 9)) == []
    assert length(PlanNights.build(@child, @plan, [], nights([]), at(~D[2026-11-20], 21))) == 14
  end

  test "groups episodes by night, small hours with the evening before" do
    wakes = [
      bedtime_wake(~D[2026-10-10], 56),
      # 01:00 on the 11th is still night 1.
      waking(~D[2026-10-11], 1, 20),
      # 03:00 on the 12th is night 2.
      waking(~D[2026-10-12], 3, 8),
      bedtime_wake(~D[2026-10-11], 12)
    ]

    [one, two] = PlanNights.build(@child, @plan, wakes, nights([]), at(~D[2026-10-12], 7))

    assert one.number == 1 and one.wakings == 1
    assert two.number == 2 and two.wakings == 1
    assert one.bedtime == at(~D[2026-10-10], 19, 30)
    assert one.bedtime_to_sleep_seconds == 56 * 60
    assert two.bedtime_to_sleep_seconds == 12 * 60
  end

  test "each waking has its pop-ins, time to sleep and crying; the night totals them" do
    wakes = [
      bedtime_wake(~D[2026-10-10], 30),
      waking(~D[2026-10-11], 2, 20),
      waking(~D[2026-10-11], 4, 10)
    ]

    [night] = PlanNights.build(@child, @plan, wakes, nights([]), at(~D[2026-10-11], 7))

    assert [first, second] = night.wakes
    assert first.started_at == at(~D[2026-10-11], 2)
    assert length(first.pop_in_times) == 2
    assert first.to_sleep_seconds == 20 * 60
    assert first.cry_seconds == 1200
    assert second.cry_seconds == 600
    assert first.ended? and second.ended?

    # The put-down's 30 minutes of crying counts too.
    assert night.cry_seconds == 30 * 60 + 20 * 60 + 10 * 60
  end

  test "carries sleep and feed figures from the nights report, and the note" do
    report =
      nights([
        %{date: ~D[2026-10-10], longest_sleep_seconds: 25_200, feeds: 2},
        %{date: ~D[2026-10-11], longest_sleep_seconds: 36_000, feeds: 0}
      ])

    [one, two] = PlanNights.build(@child, @plan, [], report, at(~D[2026-10-12], 7))

    assert one.longest_sleep_seconds == 25_200 and one.night_feeds == 2
    assert two.longest_sleep_seconds == 36_000 and two.night_feeds == 0
    assert one.note == nil
    assert two.note == "Two long cries"
  end

  test "a night with no report yet has no sleep figures" do
    [one] = PlanNights.build(@child, @plan, [], nights([]), at(~D[2026-10-10], 22))
    assert one.longest_sleep_seconds == nil and one.night_feeds == nil
    assert one.bedtime == nil and one.bedtime_to_sleep_seconds == nil
  end

  test "an episode still going counts its crying up to now" do
    start = at(~D[2026-10-10], 19, 30)
    now = DateTime.add(start, 10 * 60, :second)

    wake = %NightWake{
      kind: :bedtime,
      started_at: start,
      ended_at: nil,
      events: [ev("cry", start)]
    }

    [night] = PlanNights.build(@child, @plan, [wake], nights([]), now)
    assert night.cry_seconds == 600
    assert night.bedtime_to_sleep_seconds == nil
  end

  describe "progress/1" do
    test "lists per-night figures and the change in crying from the first night to the latest" do
      wakes = [
        bedtime_wake(~D[2026-10-10], 56),
        bedtime_wake(~D[2026-10-11], 20),
        bedtime_wake(~D[2026-10-12], 5)
      ]

      built = PlanNights.build(@child, @plan, wakes, nights([]), at(~D[2026-10-12], 22))

      progress = PlanNights.progress(built)
      assert progress.cry_seconds == [3360, 1200, 300]
      assert progress.bedtime_to_sleep_seconds == [3360, 1200, 300]
      assert progress.wakings == [0, 0, 0]
      assert progress.trend == 300 - 3360
    end

    test "no trend with one night" do
      built = PlanNights.build(@child, @plan, [], nights([]), at(~D[2026-10-10], 22))
      assert PlanNights.progress(built).trend == nil
    end
  end
end
