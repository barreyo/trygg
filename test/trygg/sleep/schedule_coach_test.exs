defmodule Trygg.Sleep.ScheduleCoachTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Sleep.{DaySchedule, DaySchedules, Phase, ScheduleCoach}

  @today ~D[2026-11-25]

  # A 100-day-old: the 3–4 month table (4 naps, windows 75/90/90/90, bedtime
  # window 19:00–20:00, wake windows 75–120).
  defp child, do: %Child{birth_date: Date.add(Date.utc_today(), -100), timezone: "Etc/UTC"}

  defp insights(opts \\ []) do
    %{
      ready?: Keyword.get(opts, :ready?, true),
      sample_days: Keyword.get(opts, :sample_days, 14),
      naps: %{
        count: %{n: 14, median: Keyword.get(opts, :naps, 4.0)},
        by_ordinal: Keyword.get(opts, :nap_lengths, [])
      },
      wake_windows: %{by_ordinal: Keyword.get(opts, :windows, [])},
      bedtime: Keyword.get(opts, :bedtime),
      morning_wake: Keyword.get(opts, :morning_wake)
    }
  end

  defp window(ordinal, minutes, n \\ 10), do: %{ordinal: ordinal, n: n, median: minutes * 60}
  defp nap(ordinal, minutes, n \\ 10), do: %{ordinal: ordinal, n: n, median: minutes * 60}
  defp clock_stat(minutes, iqr \\ 10), do: %{n: 14, median_minutes: minutes, iqr_minutes: iqr}

  defp suggest(insights, opts \\ []) do
    child = child()
    schedule = opts[:schedule]
    effective = DaySchedules.effective(child, Phase.for_child(child), schedule)

    ScheduleCoach.suggest(%{
      effective: effective,
      schedule: schedule,
      insights: insights,
      findings: Keyword.get(opts, :findings, []),
      today: @today,
      dismissed: Keyword.get(opts, :dismissed, %{}),
      history: Keyword.get(opts, :history, [])
    })
  end

  defp find(result, id), do: Enum.find(result.suggestions, &(&1.id == id))

  test "says nothing without a week of log" do
    assert %{ready?: false, suggestions: []} = suggest(insights(ready?: false))
    assert %{ready?: false, suggestions: []} = suggest(insights(sample_days: 5, naps: 2.0))
  end

  test "says nothing when the schedule matches what they do" do
    result =
      suggest(
        insights(
          windows: [window(1, 75), window(2, 90), window(3, 92)],
          bedtime: clock_stat(19 * 60 + 30)
        )
      )

    assert %{ready?: true, hold: nil, suggestions: []} = result
  end

  describe "bedtime" do
    test "eases a late bedtime 15 minutes earlier, from the usual one" do
      result = suggest(insights(bedtime: clock_stat(20 * 60 + 40)))

      assert %{change: %{bedtime_minutes: 1225}, key: "bedtime_earlier:1225"} =
               find(result, :bedtime_earlier)
    end

    test "steps from the pinned bedtime, and never past the window" do
      result =
        suggest(insights(bedtime: clock_stat(21 * 60)),
          schedule: %DaySchedule{bedtime_minutes: 20 * 60 + 10}
        )

      assert %{change: %{bedtime_minutes: 1200}} = find(result, :bedtime_earlier)
    end

    test "waits a day after one was applied" do
      history = [%{"on" => "2026-11-25", "id" => "bedtime_earlier", "title" => "x"}]

      result =
        suggest(insights(bedtime: clock_stat(21 * 60)),
          schedule: %DaySchedule{bedtime_minutes: 20 * 60 + 30},
          history: history
        )

      assert find(result, :bedtime_earlier) == nil
    end

    test "is quiet once it's in the window" do
      result =
        suggest(insights(bedtime: clock_stat(20 * 60)),
          schedule: %DaySchedule{bedtime_minutes: 19 * 60 + 45}
        )

      assert find(result, :bedtime_earlier) == nil
    end
  end

  describe "naps a day" do
    test "drops one when they've been taking fewer for a week" do
      result = suggest(insights(naps: 3.0))
      assert %{change: %{nap_count: 3}} = find(result, :nap_count)
    end

    test "ignores a fractional median that rounds to the schedule's count" do
      assert find(suggest(insights(naps: 3.5)), :nap_count) == nil
    end

    test "needs a week of days, not a few" do
      insights = put_in(insights(naps: 2.0), [:naps, :count, :n], 4)
      assert find(suggest(insights), :nap_count) == nil
    end

    test "is quiet once the schedule says so" do
      assert find(suggest(insights(naps: 3.0), schedule: %DaySchedule{nap_count: 3}), :nap_count) ==
               nil
    end
  end

  describe "wake windows" do
    test "stretches windows the log runs longer, within the guide's range" do
      result =
        suggest(
          insights(
            windows: [window(1, 95), window(2, 150), window(3, 91)],
            nap_lengths: [nap(1, 60), nap(2, 60), nap(3, 60)]
          )
        )

      assert %{
               id: :wake_windows,
               title: "Stretch the wake windows",
               change: %{wake_windows: [95, 120]}
             } =
               find(result, :wake_windows)
    end

    test "won't stretch a window whose nap is short" do
      result =
        suggest(insights(windows: [window(1, 100)], nap_lengths: [nap(1, 25)]))

      assert find(result, :wake_windows) == nil
    end

    test "shortens windows they go down earlier than" do
      result =
        suggest(
          insights(
            windows: [window(1, 75), window(2, 90), window(3, 70)],
            nap_lengths: [nap(3, 45)]
          )
        )

      assert %{title: "Shorten the wake windows", change: %{wake_windows: [nil, nil, 75]}} =
               find(result, :wake_windows)
    end

    test "keeps what's already pinned in the other slots" do
      result =
        suggest(
          insights(windows: [window(2, 120)], nap_lengths: [nap(2, 60)]),
          schedule: %DaySchedule{wake_windows: [80]}
        )

      assert %{change: %{wake_windows: [80, 120]}} = find(result, :wake_windows)
    end

    test "needs enough windows to go on" do
      result = suggest(insights(windows: [window(1, 110, 3)], nap_lengths: [nap(1, 60)]))
      assert find(result, :wake_windows) == nil
    end
  end

  describe "wake-up" do
    test "follows a steady shift away from the one they chose" do
      result =
        suggest(insights(morning_wake: clock_stat(6 * 60 + 2, 15)),
          schedule: %DaySchedule{wake_minutes: 7 * 60}
        )

      assert %{change: %{wake_minutes: 360}} = find(result, :wake_anchor)
    end

    test "ignores an unsteady one, or one that isn't pinned" do
      assert find(
               suggest(insights(morning_wake: clock_stat(360, 60)),
                 schedule: %DaySchedule{wake_minutes: 420}
               ),
               :wake_anchor
             ) == nil

      assert find(suggest(insights(morning_wake: clock_stat(360))), :wake_anchor) == nil
    end
  end

  describe "holds and dismissals" do
    test "goes quiet around a clock change" do
      result = suggest(insights(naps: 3.0), findings: [:dst])
      assert %{ready?: true, hold: %{reason: :clock_change}, suggestions: []} = result
    end

    test "goes quiet in a rough patch near a regression age, but not for the age alone" do
      assert %{hold: %{reason: :rough_patch}, suggestions: []} =
               suggest(insights(naps: 3.0), findings: [:regression_window, :night_gap])

      result = suggest(insights(naps: 3.0), findings: [:regression_window])
      assert result.hold == nil
      assert find(result, :nap_count)
    end

    test "a dismissed suggestion stays hidden for two weeks, a different one doesn't" do
      dismissed = %{"nap_count:3" => "2026-11-15"}
      assert find(suggest(insights(naps: 3.0), dismissed: dismissed), :nap_count) == nil

      old = %{"nap_count:3" => "2026-11-01"}
      assert find(suggest(insights(naps: 3.0), dismissed: old), :nap_count)

      # The same subject with a different value is a different suggestion.
      dismissed = %{"bedtime_earlier:1225" => "2026-11-24"}
      late = insights(bedtime: clock_stat(20 * 60 + 25))

      assert find(suggest(late, dismissed: dismissed), :bedtime_earlier).key ==
               "bedtime_earlier:1210"
    end

    test "shows at most three" do
      result =
        suggest(
          insights(
            naps: 3.0,
            bedtime: clock_stat(21 * 60),
            windows: [window(1, 110)],
            nap_lengths: [nap(1, 60)],
            morning_wake: clock_stat(360)
          ),
          schedule: %DaySchedule{wake_minutes: 420}
        )

      assert length(result.suggestions) == 3
      assert hd(result.suggestions).id == :bedtime_earlier
    end
  end
end
