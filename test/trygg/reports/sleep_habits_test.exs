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
end
