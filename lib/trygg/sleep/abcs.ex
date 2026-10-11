defmodule Trygg.Sleep.Abcs do
  @moduledoc """
  "The ABCs of Sleep" as data: the Taking Cara Babies 14-night plan for babies
  over 5 months, in its own steps rather than its own words. Everything the
  engine needs to run the plan lives here, so another method can be added as
  another module of the same shape (`definition/0`, `checkin_interval/1`,
  `touch/1`, `goal_wake/1`, ...).

  The plan, in brief: own room and crib; bedtime 7–8 pm (sweet spot 7–7:15);
  a routine of at most 30 minutes ending with the baby put down drowsy but
  awake; and for 14 nights, **reassure without rewarding**: when they cry, wait,
  then "pop in" for 15–20 seconds after 5 minutes, 10 minutes later, then every
  15, never picking them up, feeding or rocking them. Night feeds are weaned
  over five nights (`Trygg.Sleep.NightWeaning`) and given only when they're
  asleep. The goal is 11–12 hours in the crib; before the goal wake time, treat
  it as night; from 11 hours, get them once they're quiet.

  Not medical advice: it needs a pediatrician's go-ahead, a baby of at least 5
  months (corrected), and no fever or tooth breaking the skin.
  """

  @min_age_days 152
  @nights 14

  # Seconds to wait before the n-th pop-in of a waking (n = 0, 1, 2…): 5 minutes
  # after the crying starts, 10 minutes after that one, then every 15.
  @intervals [300, 600]
  @interval_after 900

  # How long to stay at a pop-in.
  @stay {15, 20}

  # Goal time in the crib, in hours.
  @goal_hours {11, 12}

  @bedtime_window {19 * 60, 20 * 60}
  @routine_minutes 30

  @preflight [
    {"p-room", "They sleep in their own room, in their own crib, for the whole plan."},
    {"p-crib-safe", "The mattress is at its lowest and the crib is clear of mobiles and toys."},
    {"p-dark-sound",
     "The room is dark, cool and comfortable, with a sound machine that stays on all night."},
    {"p-bedtime", "Bedtime is between 7 and 8 pm."},
    {"p-routine",
     "The bedtime routine is 30 minutes or less, ends in their room, and finishes with them put down drowsy but awake."},
    {"p-feeds", "Daytime feeds are every 2–4 hours, so calories come in the day."},
    {"p-well", "They aren't ill, have no fever and no tooth breaking the skin right now."},
    {"p-commit", "Both of us are ready to stay consistent for 14 nights."}
  ]

  @doc "The corrected age in days from which the plan opens (5 months)."
  def min_age_days, do: @min_age_days

  @doc "How many nights the plan runs."
  def nights, do: @nights

  @doc "The identifying facts of the plan."
  def definition do
    %{
      id: :abcs,
      name: "The ABCs of Sleep",
      nights: @nights,
      min_age_days: @min_age_days,
      goal_hours: @goal_hours,
      bedtime_window: @bedtime_window,
      routine_minutes: @routine_minutes,
      stay_seconds: @stay
    }
  end

  @doc "The pre-flight checklist as `{id, text}`; all of it is ticked by hand."
  def preflight, do: @preflight

  @doc "Ids of the pre-flight items."
  def preflight_ids, do: Enum.map(@preflight, &elem(&1, 0))

  @doc "Seconds to wait before pop-in number `index` (0-based) of a waking."
  def checkin_interval(index) when is_integer(index) and index >= 0,
    do: Enum.at(@intervals, index, @interval_after)

  @doc "The `{min, max}` seconds to stay at a pop-in."
  def stay_seconds, do: @stay

  @doc """
  How to comfort at a pop-in on night `n`: `:touch` on nights 1 and 2 (rub their
  head, pat them, never pick them up; lay them down once if they're standing),
  `:voice` from night 3 (words only).
  """
  def touch(night) when is_integer(night) and night <= 2, do: :touch
  def touch(night) when is_integer(night), do: :voice

  @doc """
  The goal wake window for a bedtime (a `DateTime`): `{earliest, latest}`,
  11 and 12 hours later.
  """
  def goal_wake(%DateTime{} = bedtime) do
    {lo, hi} = @goal_hours
    {DateTime.add(bedtime, lo * 3600, :second), DateTime.add(bedtime, hi * 3600, :second)}
  end

  @doc """
  What to do about a waking at `now` given the night's bedtime: `:night` before
  the goal window (pop-ins until asleep), `:morning` from 11 hours on (get them
  once they're quiet; praise and lights on).
  """
  def morning_state(%DateTime{} = bedtime, %DateTime{} = now) do
    {earliest, _latest} = goal_wake(bedtime)
    if DateTime.compare(now, earliest) == :lt, do: :night, else: :morning
  end

  @doc "The bedtime window as `{from, to}` in minutes after midnight."
  def bedtime_window, do: @bedtime_window
end
