defmodule Trygg.Reports.SleepHabitsTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias Trygg.Reports.SleepHabits

  @now ~U[2026-10-10 12:00:00Z]
  @today ~D[2026-10-10]
  @child %Child{timezone: "Etc/UTC"}

  defp at(hour, minute \\ 0, date \\ @today) do
    DateTime.new!(date, Time.new!(hour, minute, 0), "Etc/UTC")
  end

  defp sleep(started, ended, data \\ %{}),
    do: %Entry{type: :sleep, started_at: started, ended_at: ended, data: data}

  defp bottle(at), do: %Entry{type: :feeding, started_at: at, ended_at: at, data: %{}}

  defp nursing(started, ended),
    do: %Entry{type: :breastfeeding, started_at: started, ended_at: ended, data: %{}}

  defp summarize(entries), do: SleepHabits.summarize(@child, entries, @today, @now)

  describe "cues" do
    test "counts sleeps with a cue noted, and how many started overtired" do
      result =
        summarize([
          sleep(at(7), at(8), %{"cue" => "ready"}),
          sleep(at(9), at(10), %{"cue" => "overtired"}),
          sleep(at(11), at(11, 30))
        ])

      assert %{sleeps: 3, cued: 2, overtired: 1} = result.today
      assert %{sleeps: 3, cued: 2, overtired: 1} = result.week
    end

    test "median time awake before sleeps noted as a cue needs three samples" do
      # Awake 50, 60 and 55 minutes before three "ready" sleeps.
      ready = %{"cue" => "ready"}

      entries = [
        sleep(at(6), at(7)),
        sleep(at(7, 50), at(8, 30), ready),
        sleep(at(9, 30), at(10), ready),
        sleep(at(10, 55), at(11), ready),
        # Two "tired" sleeps are too few to report.
        sleep(at(11, 30), at(11, 40), %{"cue" => "tired"}),
        sleep(at(12), nil, %{"cue" => "tired"})
      ]

      assert %{"ready" => %{n: 3, median_seconds: 3300}} = summarize(entries).cue_windows
      refute Map.has_key?(summarize(entries).cue_windows, "tired")
    end

    test "an awake stretch over four hours isn't a wake window" do
      entries = [
        sleep(at(0), at(1)),
        sleep(at(7), at(8), %{"cue" => "ready"})
      ]

      assert summarize(entries).cue_windows == %{}
    end
  end

  describe "feed to sleep" do
    test "a sleep within 10 minutes of a feed counts as fed to sleep" do
      result =
        summarize([
          bottle(at(7, 55)),
          sleep(at(8), at(9)),
          bottle(at(9, 30)),
          sleep(at(10, 30), at(11))
        ])

      assert %{sleeps: 2, measured: 2, fed_to_sleep: 1} = result.today
    end

    test "a breastfeeding session still running when sleep starts counts" do
      result = summarize([nursing(at(7, 40), at(8, 20)), sleep(at(8), at(9))])
      assert %{measured: 1, fed_to_sleep: 1} = result.today
    end

    test "a sleep with no feed in the six hours before it isn't measured" do
      result = summarize([bottle(at(1)), sleep(at(8), at(9))])
      assert %{sleeps: 1, measured: 0, fed_to_sleep: 0} = result.today
    end

    test "a feed after the sleep started doesn't count" do
      result = summarize([sleep(at(8), at(9)), bottle(at(8, 5))])
      assert %{measured: 0} = result.today
    end
  end

  describe "windows" do
    test "today is a subset of the week; older sleeps and tomorrow's are left out" do
      result =
        summarize([
          sleep(at(8, 0, ~D[2026-10-09]), at(9, 0, ~D[2026-10-09])),
          sleep(at(8, 0, ~D[2026-10-03]), at(9, 0, ~D[2026-10-03])),
          sleep(at(8), at(9))
        ])

      assert result.today.sleeps == 1
      assert result.week.sleeps == 2
    end

    test "no entries gives zeroes and no windows" do
      assert %{today: %{sleeps: 0}, week: %{sleeps: 0}, cue_windows: %{}} = summarize([])
    end
  end

  describe "cue_adjustment/3" do
    # Builds sleeps of 30 minutes each, every one starting `awake` minutes after
    # the last ended, with the given cue.
    defp sleeps_with(samples) do
      {entries, _end} =
        samples
        |> Enum.with_index(1)
        |> Enum.map_reduce(at(6, 0, Date.add(@today, -2)), fn {{awake, cue}, _id}, prev_end ->
          started = DateTime.add(prev_end, awake * 60, :second)
          finished = DateTime.add(started, 30 * 60, :second)
          data = if cue, do: %{"cue" => cue}, else: %{}
          {sleep(started, finished, data), finished}
        end)

      entries
    end

    defp adjustment(entries), do: SleepHabits.cue_adjustment(@child, entries, @today)

    test "ready cues after a shorter stretch awake than usual pull windows earlier" do
      # An opening sleep to measure from, then 5 ready sleeps after 75 minutes
      # and 7 after 90 (median overall 90, median ready 75).
      samples = [{0, nil}] ++ List.duplicate({75, "ready"}, 5) ++ List.duplicate({90, nil}, 7)

      assert %{factor: factor, ready_seconds: 4500, overall_seconds: 5400, n_ready: 5} =
               adjustment(sleeps_with(samples))

      # ratio 0.833 shrunk by 5 / (5 + 6): about 0.92.
      assert_in_delta factor, 0.924, 0.005
    end

    test "ready cues after a longer stretch pull windows later, within bounds" do
      samples = [{0, nil}] ++ List.duplicate({100, "ready"}, 6) ++ List.duplicate({60, nil}, 6)
      assert %{factor: factor} = adjustment(sleeps_with(samples))
      assert factor > 1.0 and factor <= 1.15
    end

    test "never beyond 0.85 to 1.15" do
      samples = [{0, nil}] ++ List.duplicate({20, "ready"}, 12) ++ List.duplicate({120, nil}, 12)
      assert %{factor: 0.85} = adjustment(sleeps_with(samples))
    end

    test "needs four ready sleeps and eight with a known wake window" do
      few_ready = [{0, nil}] ++ List.duplicate({75, "ready"}, 3) ++ List.duplicate({90, nil}, 9)
      assert adjustment(sleeps_with(few_ready)) == nil

      few_sleeps = [{0, nil}] ++ List.duplicate({75, "ready"}, 4) ++ List.duplicate({90, nil}, 2)
      assert adjustment(sleeps_with(few_sleeps)) == nil

      assert adjustment([]) == nil
    end

    test "only the last 14 days count" do
      old =
        for e <- sleeps_with([{0, nil}] ++ List.duplicate({75, "ready"}, 12)),
            do: shift_days(e, -20)

      assert adjustment(old) == nil
    end

    defp shift_days(entry, days) do
      %{
        entry
        | started_at: DateTime.add(entry.started_at, days * 86_400, :second),
          ended_at: DateTime.add(entry.ended_at, days * 86_400, :second)
      }
    end
  end
end
