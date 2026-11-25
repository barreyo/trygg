defmodule Trygg.Reports.ScheduleFit do
  @moduledoc """
  How the last couple of weeks lined up with the family's sleep day: did they
  take the number of naps the schedule has, how long were they actually awake
  before each nap against the schedule's wake window, and how far were bedtime
  and the morning wake from the ones the family chose.

  It's a look back, not a verdict: a schedule that doesn't fit may be the wrong
  schedule or a baby in a rough week. Only complete days count (not today, and
  not days with no sleep logged), and a figure appears once there's enough
  behind it. `Trygg.Sleep.ScheduleCoach` is what turns a persistent gap into a
  suggestion.

  Pure: takes the child, a `Trygg.Sleep.DaySchedules.effective/4` map and the
  recent `%Day{}`s.
  """

  alias Trygg.Families.Child
  alias Trygg.Reports.Stats
  alias Trygg.Sleep.Schedules

  @min_days 5
  @min_windows 3
  @close_minutes 30

  @doc "How many complete days are needed before anything is scored."
  def min_days, do: @min_days

  @doc """
  `score(child, effective, days)` returns `nil` without a schedule, else
  `%{ready?, days, naps, windows, bedtime, wake}`.

    * `naps` — `%{scheduled, matched, median}`: days with the scheduled count
      of naps, out of `days`, and the median count (guide mode only).
    * `windows` — per nap with at least #{@min_windows} windows logged,
      `%{ordinal, scheduled, n, median, delta}` in minutes (guide mode only).
    * `bedtime`, `wake` — only for a time the family chose:
      `%{scheduled, n, median_delta, close}` where `median_delta` is minutes
      later (positive) or earlier than chosen and `close` how many fell within
      #{@close_minutes} minutes of it.
  """
  def score(_child, nil, _days), do: nil

  def score(%Child{} = child, effective, days) do
    complete =
      days
      |> Enum.reject(& &1.now?)
      |> Enum.filter(&(&1.total_sleep_seconds > 0))

    if length(complete) < @min_days do
      %{ready?: false, days: length(complete)}
    else
      %{
        ready?: true,
        days: length(complete),
        naps: naps(effective, complete),
        windows: windows(effective, complete),
        bedtime: clock(child, effective.bedtime, complete, & &1.bedtime, true),
        wake: clock(child, effective.wake, complete, & &1.morning_wake, false)
      }
    end
  end

  defp naps(%{mode: :guide, nap_count: %{value: scheduled}}, days) do
    counts = Enum.map(days, &length(&1.naps))

    %{
      scheduled: scheduled,
      matched: Enum.count(counts, &(&1 == scheduled)),
      median: Stats.median(counts)
    }
  end

  defp naps(_effective, _days), do: nil

  defp windows(%{mode: :guide, slots: slots}, days) do
    closed = days |> Enum.flat_map(& &1.wake_windows) |> Enum.reject(& &1.open?)

    for slot <- slots,
        minutes = for(w <- closed, w.ordinal == slot.ordinal, do: w.seconds / 60),
        length(minutes) >= @min_windows do
      median = Stats.median(minutes)

      %{
        ordinal: slot.ordinal,
        scheduled: slot.window.minutes,
        n: length(minutes),
        median: round(median),
        delta: round(median - slot.window.minutes)
      }
    end
  end

  defp windows(_effective, _days), do: []

  # Only a time the family chose is held against what happened.
  defp clock(child, %{source: :pinned, minutes: scheduled}, days, pick, after_midnight?) do
    deltas =
      for day <- days, at = pick.(day), is_struct(at, DateTime) do
        minutes = Schedules.local_minutes(child, at)
        minutes = if after_midnight? and minutes < 6 * 60, do: minutes + 24 * 60, else: minutes
        minutes - scheduled
      end

    if length(deltas) >= @min_days do
      %{
        scheduled: scheduled,
        n: length(deltas),
        median_delta: round(Stats.median(deltas)),
        close: Enum.count(deltas, &(abs(&1) <= @close_minutes))
      }
    end
  end

  defp clock(_child, _chosen, _days, _pick, _after_midnight?), do: nil
end
