defmodule Trygg.Reports.PlanNights do
  @moduledoc """
  The nightly log of a sleep-training plan, in the guide's own shape (its "night
  chart"): for each night, when they were put down and how long it took to fall
  asleep, each waking with its pop-ins, time to sleep and time spent crying, and
  the totals, so progress shows across the 14 nights.

  Pure: takes the child, the plan, its night wakings (`Trygg.Sleep.NightWake`
  with `plan_id` set) and a `Trygg.Reports.Nights` summary for the sleep and feed
  figures.
  """

  alias Trygg.Sleep.{Checkins, Definitions, Plans}

  @doc """
  One entry per night from night 1 to the night at `now` (at most the plan's
  length), oldest first:

      %{number, date, bedtime, bedtime_to_sleep_seconds, wakes, wakings,
        cry_seconds, longest_sleep_seconds, night_feeds, note}

  `wakes` are the night's waking episodes oldest first, each `%{started_at,
  asleep_at, pop_in_times, cry_seconds, to_sleep_seconds, ended?}`.
  """
  def build(child, plan, wakes, nights, now) do
    last = min(Plans.night_number(plan, child, now), Definitions.nights(plan))

    by_night =
      wakes
      |> Enum.sort_by(& &1.started_at, DateTime)
      |> Enum.group_by(&Plans.night_number(plan, child, &1.started_at))

    for number <- 1..last//1 do
      date = Plans.night_date(plan, number)
      episodes = Map.get(by_night, number, [])
      bedtime = Enum.find(episodes, &(&1.kind == :bedtime))
      wakings = Enum.filter(episodes, &(&1.kind == :waking))
      night = Enum.find(nights.nights, &(&1.date == date))
      all = Enum.map(episodes, &episode(&1, now, plan, number))

      %{
        number: number,
        date: date,
        bedtime: bedtime && bedtime.started_at,
        bedtime_to_sleep_seconds: bedtime && episode(bedtime, now, plan, number).to_sleep_seconds,
        wakes: Enum.map(wakings, &episode(&1, now, plan, number)),
        wakings: length(wakings),
        cry_seconds: all |> Enum.map(& &1.cry_seconds) |> Enum.sum(),
        longest_sleep_seconds: night && night.longest_sleep_seconds,
        night_feeds: night && night.feeds,
        note: Map.get(plan.notes, Integer.to_string(number))
      }
    end
  end

  defp episode(wake, now, plan, number) do
    state = Checkins.state(wake.events, wake.ended_at || now, Definitions.schedule(plan, number))

    %{
      started_at: wake.started_at,
      asleep_at: state.asleep_at,
      pop_in_times: state.pop_in_times,
      cry_seconds: wake.cry_seconds || state.cry_seconds,
      to_sleep_seconds:
        state.asleep_at && DateTime.diff(state.asleep_at, wake.started_at, :second),
      ended?: not is_nil(wake.ended_at)
    }
  end

  @doc """
  Across the nights: `%{cry_seconds, bedtime_to_sleep_seconds, wakings}` as
  lists (one value per night, `nil` where a night has none), for charts, and
  `trend` the change in crying between the first and the latest night (negative
  is better) when there are at least two nights.
  """
  def progress(nights) do
    cry = Enum.map(nights, & &1.cry_seconds)

    %{
      cry_seconds: cry,
      bedtime_to_sleep_seconds: Enum.map(nights, & &1.bedtime_to_sleep_seconds),
      wakings: Enum.map(nights, & &1.wakings),
      trend: if(length(cry) >= 2, do: List.last(cry) - hd(cry))
    }
  end
end
