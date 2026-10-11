defmodule Trygg.Reports.DayPlanTest do
  use ExUnit.Case, async: true

  import Trygg.ReportDays

  alias Trygg.Reports.Day
  alias Trygg.Reports.DayPlan

  @date ~D[2026-10-10]

  defp t(hour, minute \\ 0), do: at(@date, Time.new!(hour, minute, 0))

  defp day(entries, now), do: Day.build(child(), @date, entries, now)

  defp night(id \\ 1), do: sleep(id, at(Date.add(@date, -1), ~T[20:00:00]), t(7))

  defp prediction(attrs) do
    Map.merge(
      %{
        state: :awake,
        next_nap: nil,
        wake_pressure: nil,
        schedule: [],
        morning_wake: nil,
        bedtime: nil,
        transition?: false
      },
      Map.new(attrs)
    )
  end

  defp nap_entry(ordinal, start, finish),
    do: %{kind: :nap, ordinal: ordinal, start: start, end: finish, label: "Nap #{ordinal}"}

  defp bed_entry(at), do: %{kind: :bed, ordinal: nil, start: at, end: at, label: "Bedtime"}

  defp ids(plan), do: Enum.map(plan.items, & &1.id)
  defp item(plan, id), do: Enum.find(plan.items, &(&1.id == id))

  test "lists the day in order: wake, what's done, what's next, bedtime" do
    now = t(12)
    today = day([night(), sleep(2, t(9, 30), t(10, 30))], now)

    prediction =
      prediction(
        next_nap: %{
          ordinal: 2,
          at: t(12, 15),
          range: %{from: t(12), to: t(12, 30), label: "12:00–12:30"},
          source: :history
        },
        wake_pressure: %{state: :approaching, awake_seconds: 5400, typical_seconds: 6300},
        schedule: [
          nap_entry(2, t(12, 15), t(13, 15)),
          nap_entry(3, t(15, 30), t(16, 30)),
          bed_entry(t(19, 30))
        ],
        bedtime: %{at: t(19, 30), label: "19:30", source: :blended, shifted_by_seconds: 0}
      )

    plan = DayPlan.build(child(), today, prediction, now)

    assert ids(plan) == ["wake", "nap-1", "nap-2", "nap-3", "bed"]
    assert Enum.map(plan.items, & &1.state) == [:done, :done, :due, :upcoming, :upcoming]

    nap2 = item(plan, "nap-2")
    assert nap2.range == %{from: t(12), to: t(12, 30)}
    assert nap2.source == :history
    assert nap2.seconds == 3600

    # Only the next nap carries the range; later ones are plain estimates.
    assert item(plan, "nap-3").range == nil
    assert item(plan, "nap-3").estimate?
    assert item(plan, "bed").source == :blended
    assert plan.day_sleep_seconds == 3600
  end

  test "each nap and bedtime knows how long they were awake leading into it" do
    now = t(12)
    today = day([night(), sleep(2, t(9, 30), t(10, 30))], now)

    prediction =
      prediction(
        schedule: [nap_entry(2, t(12, 15), t(13, 15)), bed_entry(t(19, 30))],
        bedtime: %{at: t(19, 30), label: "19:30", source: :history, shifted_by_seconds: 0}
      )

    plan = DayPlan.build(child(), today, prediction, now)

    # Woke at 07:00, napped at 09:30; napped again at 12:15 after waking at 10:30.
    assert item(plan, "nap-1").awake_before == 150 * 60
    assert item(plan, "nap-2").awake_before == 105 * 60
    assert item(plan, "bed").awake_before == 375 * 60
  end

  test "a running nap is :now and projects the rest of the day after it" do
    now = t(12, 45)
    today = day([night(), sleep(2, t(12, 15), nil)], now)

    prediction =
      prediction(
        state: :asleep,
        schedule: [nap_entry(2, t(15, 30), t(16, 30)), bed_entry(t(19, 30))],
        bedtime: %{at: t(19, 30), label: "19:30", source: :history, shifted_by_seconds: 0}
      )

    plan = DayPlan.build(child(), today, prediction, now)

    assert %{state: :now, seconds: 1800, end: nil} = item(plan, "nap-1")
    assert item(plan, "nap-2").state == :upcoming
    # The running nap has no end yet, so there's no awake time to attribute to nap 2.
    assert item(plan, "nap-2").awake_before == nil
  end

  test "a nap that just started isn't listed twice when the prediction hasn't caught up" do
    now = t(12, 45)
    today = day([night(), sleep(2, t(8), t(9)), sleep(3, t(12, 45), nil)], now)

    # Still the awake prediction, which lists nap 2 as upcoming.
    prediction =
      prediction(
        state: :awake,
        next_nap: %{ordinal: 2, at: t(12, 45), range: nil, source: :history},
        wake_pressure: %{state: :past, awake_seconds: 13_000, typical_seconds: 7200},
        schedule: [nap_entry(2, t(12, 45), t(13, 45)), nap_entry(3, t(15, 30), t(16, 30))]
      )

    plan = DayPlan.build(child(), today, prediction, now)
    assert ids(plan) == ["wake", "nap-1", "nap-2", "nap-3"]
    assert item(plan, "nap-2").state == :now
  end

  test "a bedtime that has happened is done, and isn't listed twice" do
    now = t(21)
    today = day([night(), sleep(2, t(19, 40), nil)], now)

    prediction =
      prediction(
        state: :asleep,
        schedule: [bed_entry(t(19, 30))],
        bedtime: %{at: t(19, 30), label: "19:30", source: :history, shifted_by_seconds: 0}
      )

    plan = DayPlan.build(child(), today, prediction, now)

    assert [%{kind: :bed, state: :done, estimate?: false}] =
             Enum.filter(plan.items, &(&1.kind == :bed))
  end

  test "without a logged morning wake it shows the usual one, as an estimate" do
    now = t(9)
    today = day([], now)

    prediction =
      prediction(morning_wake: %{actual?: false, at: t(7, 15), label: "07:15"})

    assert %{items: [%{kind: :wake, estimate?: true, state: :done}]} =
             DayPlan.build(child(), today, prediction, now)
  end

  test "with no prediction only what has happened is listed" do
    now = t(12)
    today = day([night(), sleep(2, t(9, 30), t(10, 30))], now)

    plan = DayPlan.build(child(), today, nil, now)
    assert ids(plan) == ["wake", "nap-1"]
  end

  test "a bedtime estimate before 17:00 is left out as implausible" do
    now = t(12)
    today = day([night(), sleep(2, t(9, 30), t(10, 30))], now)

    prediction =
      prediction(
        schedule: [bed_entry(t(12, 45))],
        bedtime: %{at: t(12, 45), label: "12:45", source: :blended, shifted_by_seconds: 0}
      )

    assert ids(DayPlan.build(child(), today, prediction, now)) == ["wake", "nap-1"]

    evening =
      prediction(
        schedule: [bed_entry(t(17))],
        bedtime: %{at: t(17), label: "17:00", source: :history, shifted_by_seconds: 0}
      )

    assert "bed" in ids(DayPlan.build(child(), today, evening, now))
  end

  test "a nap window that has already closed is just due now, without a stale range" do
    now = t(16)
    today = day([night(), sleep(2, t(9, 30), t(10, 30))], now)

    prediction =
      prediction(
        next_nap: %{
          ordinal: 2,
          at: t(12, 15),
          range: %{from: t(12), to: t(12, 30), label: "12:00–12:30"},
          source: :history
        },
        wake_pressure: %{state: :past, awake_seconds: 19_800, typical_seconds: 6300},
        schedule: [nap_entry(2, t(16), t(17))]
      )

    assert %{state: :due, range: nil} =
             item(DayPlan.build(child(), today, prediction, now), "nap-2")
  end

  test "an empty day is an empty plan" do
    assert %{items: [], day_sleep_seconds: 0} = DayPlan.build(child(), day([], t(6)), nil, t(6))
  end
end
