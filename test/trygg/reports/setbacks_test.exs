defmodule Trygg.Reports.SetbacksTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Reports.{Day, Setbacks}

  # Stockholm: clocks go back on 2026-10-25.
  @child %Child{timezone: "Etc/UTC"}
  @today ~D[2026-10-11]

  defp at(date, hour, minute \\ 0),
    do: DateTime.new!(date, Time.new!(hour, minute, 0), "Etc/UTC")

  defp night(offset, attrs \\ []) do
    date = Date.add(@today, -offset)

    Map.merge(
      %{
        date: date,
        bedtime: at(date, 19),
        wake: at(Date.add(date, 1), 6),
        wakings: 0,
        longest_waking_seconds: 0
      },
      Map.new(attrs)
    )
  end

  defp nights(list), do: %{nights: list}

  defp nap(ordinal, minutes),
    do: %{
      ordinal: ordinal,
      running?: false,
      seconds: minutes * 60,
      entry: %{data: %{}},
      end: nil,
      start: nil
    }

  defp day(offset, attrs) do
    date = Date.add(@today, -offset)

    struct!(
      Day,
      Map.merge(
        %{date: date, naps: [], total_sleep_seconds: 13 * 3600, now?: false},
        Map.new(attrs)
      )
    )
  end

  defp ctx(attrs) do
    Map.merge(
      %{
        child: @child,
        age_days: 150,
        nights: nights([]),
        days: [],
        insights: %{bedtime: %{iqr_minutes: 10}},
        today: @today
      },
      Map.new(attrs)
    )
  end

  defp ids(findings), do: Enum.map(findings, & &1.id)

  test "a quiet fortnight has nothing to say" do
    nights = for i <- 1..7, do: night(i)
    assert Setbacks.detect(ctx(nights: nights(nights))) == []
  end

  test "a newborn gets nothing but a clock change" do
    nights = for i <- 1..7, do: night(i, wake: at(Date.add(@today, -i + 1), 4))
    assert Setbacks.detect(ctx(age_days: 30, nights: nights(nights))) == []
  end

  describe "early_wake" do
    test "three early mornings in the last week" do
      nights =
        for i <- 1..7 do
          date = Date.add(@today, -i)
          wake = if i <= 3, do: at(Date.add(date, 1), 4, 45), else: at(Date.add(date, 1), 6)
          night(i, wake: wake)
        end

      [finding] = Setbacks.detect(ctx(nights: nights(nights)))
      assert finding.id == :early_wake
      assert finding.playbook == :early_morning
      assert finding.detail =~ "3 of the last 7"
    end

    test "two isn't enough" do
      nights =
        for i <- 1..7,
            do: night(i, wake: at(Date.add(@today, -i + 1), if(i <= 2, do: 4, else: 6)))

      refute :early_wake in ids(Setbacks.detect(ctx(nights: nights(nights))))
    end
  end

  test "a night gap shows once it's three nights of an hour or more" do
    nights = for i <- 1..7, do: night(i, longest_waking_seconds: if(i <= 3, do: 4000, else: 0))
    assert :night_gap in ids(Setbacks.detect(ctx(nights: nights(nights))))

    nights = for i <- 1..7, do: night(i, longest_waking_seconds: if(i <= 2, do: 4000, else: 0))
    refute :night_gap in ids(Setbacks.detect(ctx(nights: nights(nights))))
  end

  test "sleep debt: three days well under the range for the age" do
    days = for i <- 3..1//-1, do: day(i, total_sleep_seconds: 10 * 3600)
    [finding] = Setbacks.detect(ctx(days: days))
    assert finding.id == :sleep_debt
    assert finding.detail =~ "10.0 hours"

    days = for i <- 3..1//-1, do: day(i, total_sleep_seconds: 12 * 3600 + 1800)
    assert Setbacks.detect(ctx(days: days)) == []
  end

  test "short naps: the first two of the day under 45 minutes" do
    days =
      for i <- 6..1//-1, do: day(i, naps: [nap(1, 30), nap(2, 35), nap(3, 20)])

    assert :short_naps in ids(Setbacks.detect(ctx(days: days)))

    days = for i <- 6..1//-1, do: day(i, naps: [nap(1, 60), nap(2, 70), nap(3, 20)])
    refute :short_naps in ids(Setbacks.detect(ctx(days: days)))
  end

  test "the third nap getting thin between six and twelve months" do
    days = for i <- 7..1//-1, do: day(i, naps: [nap(1, 60), nap(2, 60), nap(3, 15)])
    assert :nap_drop in ids(Setbacks.detect(ctx(age_days: 220, days: days)))
    refute :nap_drop in ids(Setbacks.detect(ctx(age_days: 150, days: days)))
  end

  test "too little time awake before bed on three evenings" do
    entries =
      for i <- 1..5 do
        date = Date.add(@today, -i)
        nap = at(date, 16, 40)
        night = at(date, 19)

        [
          %Trygg.Log.Entry{
            type: :sleep,
            started_at: DateTime.add(nap, -45 * 60),
            ended_at: nap,
            data: %{}
          },
          %Trygg.Log.Entry{
            type: :sleep,
            started_at: night,
            ended_at: DateTime.add(night, 10 * 3600),
            data: %{}
          }
        ]
      end
      |> List.flatten()

    # At 6 months the guide asks for about 3 hours awake before bed.
    [finding] = Setbacks.detect(ctx(age_days: 215, entries: entries))
    assert finding.id == :late_catnap
    assert finding.detail =~ "180 minutes"

    # At 3–6 months it's 2 hours, and 140 minutes is enough.
    assert Setbacks.detect(ctx(age_days: 150, entries: entries)) == []
  end

  test "a wandering bedtime" do
    assert :bedtime_drift in ids(Setbacks.detect(ctx(insights: %{bedtime: %{iqr_minutes: 50}})))
    refute :bedtime_drift in ids(Setbacks.detect(ctx(insights: %{bedtime: %{iqr_minutes: 20}})))
    refute :bedtime_drift in ids(Setbacks.detect(ctx(insights: %{bedtime: nil})))
  end

  test "a regression window" do
    assert :regression_window in ids(Setbacks.detect(ctx(age_days: 125)))
    refute :regression_window in ids(Setbacks.detect(ctx(age_days: 150)))
  end

  describe "clock change" do
    test "turns up in the ten days before" do
      child = %Child{timezone: "Europe/Stockholm"}
      findings = Setbacks.detect(ctx(child: child, age_days: 40, today: ~D[2026-10-20]))
      assert [%{id: :dst, title: title}] = findings
      assert title == "The clocks go back in 5 days"
    end

    test "waits until it's near" do
      child = %Child{timezone: "Europe/Stockholm"}
      far = Setbacks.detect(ctx(child: child, today: ~D[2026-10-01]))
      refute :dst in ids(far)
      near = Setbacks.detect(ctx(child: child, today: ~D[2026-10-20]))
      assert :dst in ids(near)
    end
  end
end
