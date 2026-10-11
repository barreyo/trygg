defmodule Trygg.Reports do
  @moduledoc """
  Calendar days, sleep/feeding/diaper insights, predictions and alerts for a
  child.

  Reads require the `:viewer` role. All analysis is derived from `Trygg.Log`
  entries and `Trygg.Growth` measurements; nothing is persisted here.
  """

  alias Trygg.Accounts.Scope
  alias Trygg.Families
  alias Trygg.Families.Child
  alias Trygg.Growth
  alias Trygg.Log
  alias Trygg.Reports.Alerts
  alias Trygg.Reports.Day
  alias Trygg.Reports.DayPlan
  alias Trygg.Reports.Diapers
  alias Trygg.Reports.Feeding
  alias Trygg.Reports.Insights
  alias Trygg.Reports.Nights
  alias Trygg.Reports.PredictionLedger
  alias Trygg.Reports.Rhythm
  alias Trygg.Reports.Shifts
  alias Trygg.Reports.SleepHabits

  # Long enough to reconstruct last night's cluster (and a late bedtime).
  @lookback_hours 36
  # Change detection needs 14 baseline days + 3 recent + today, whatever the
  # window being viewed.
  @shift_days 18
  @outlook_window 14

  @doc "One local calendar day of segmented log data."
  def day(%Scope{} = scope, %Child{} = child, %Date{} = date, now \\ DateTime.utc_now()) do
    Families.authorize!(scope, child, :viewer)
    List.first(days_unchecked(scope, child, date, date, now))
  end

  @doc """
  Segmented days from `from_date` through `to_date` (inclusive), oldest first.
  """
  def days(
        %Scope{} = scope,
        %Child{} = child,
        %Date{} = from_date,
        %Date{} = to_date,
        now \\ DateTime.utc_now()
      ) do
    Families.authorize!(scope, child, :viewer)
    days_unchecked(scope, child, from_date, to_date, now)
  end

  @doc """
  Sleep, feeding, diaper and growth insights over a local-day window ending
  today, plus predictions for the rest of today and a list of plain-language
  alerts.

  `window` is a day count (`7`, `14`, `30`, `90`, …) or `:all` (from the first
  log entry, capped at a year). Change detection (`:shifts`) always looks at
  the last #{@shift_days} days regardless of `window`.
  """
  def summary(%Scope{} = scope, %Child{} = child, window, now \\ DateTime.utc_now()) do
    Families.authorize!(scope, child, :viewer)
    today = Child.local_today(child)
    from = window_start(scope, child, today, window)
    shift_from = Date.add(today, 1 - @shift_days)
    fetch_from = if Date.before?(shift_from, from), do: shift_from, else: from

    {all_days, entries} = load_days(scope, child, fetch_from, today, now)
    days = Enum.drop(all_days, Date.diff(from, fetch_from))
    today_day = List.last(days) || Day.build(child, today, [], now)

    weight = recent_weight(scope, child)
    cues = SleepHabits.cue_adjustment(child, entries, today)

    insights =
      Insights.summarize(
        child,
        days,
        today_day,
        now,
        Keyword.put(PredictionLedger.prediction_opts(child.id), :cue_factor, cues && cues.factor)
      )

    feeding = Feeding.summarize(child, days, now, weight: weight)
    diapers = Diapers.summarize(child, days, now)

    shifts =
      Shifts.summarize(Enum.take(all_days, -@shift_days), Feeding.summarize(child, all_days, now))

    growth = Growth.velocity(scope, child)

    alerts =
      Alerts.build(
        %{feeding: feeding, diapers: diapers, shifts: shifts, growth: growth},
        unit_system: scope.user.unit_system
      )

    Map.merge(insights, %{
      feeding: feeding,
      diapers: diapers,
      shifts: shifts,
      growth: growth,
      alerts: alerts,
      rhythm: Rhythm.summarize(child, days, today_day, now),
      today: today_day,
      cue_adjustment: cues
    })
  end

  @doc """
  Everything the printable PDF report needs: the `summary/4` for `window`,
  the last seven local days for the calendar, and the child's full growth
  history with latest weight/height. Requires `:viewer`.
  """
  def export(%Scope{} = scope, %Child{} = child, window, now \\ DateTime.utc_now()) do
    Families.authorize!(scope, child, :viewer)
    now = DateTime.truncate(now, :second)
    today = Child.local_today(child)

    %{
      window: window,
      today: today,
      generated_at: now,
      summary: summary(scope, child, window, now),
      week: days(scope, child, Date.add(today, -6), today, now),
      measurements: Growth.list_measurements(scope, child),
      latest_weight: Growth.latest_weight(scope, child),
      latest_height: Growth.latest_height(scope, child)
    }
  end

  @doc """
  The slice of `summary/4` the Home screen needs: today's sleep prediction and
  wake pressure, the "typical day" rhythm, the next-feed estimate, hydration
  status and the alert list. Built from the last #{@outlook_window} days.
  """
  def outlook(%Scope{} = scope, %Child{} = child, now \\ DateTime.utc_now()) do
    s = summary(scope, child, @outlook_window, now)

    %{
      prediction: s.prediction,
      rhythm: s.rhythm,
      next_feed: s.feeding.next_feed,
      cluster: s.feeding.cluster,
      diapers: %{flags: s.diapers.flags, dry_seconds: s.diapers.dry_seconds},
      alerts: s.alerts
    }
  end

  @doc """
  How the last few nights went (`Trygg.Reports.Nights`): bedtime and wake,
  sleep, wakings, the longest unbroken sleep and the longest stretch between
  feeds. Requires `:viewer`.
  """
  def nights(%Scope{} = scope, %Child{} = child, now \\ DateTime.utc_now()) do
    Families.authorize!(scope, child, :viewer)
    today = Child.local_today(child)
    # One more day than the nights shown: each night needs the morning after it.
    {days, entries} = load_days(scope, child, Date.add(today, -Nights.count()), today, now)
    Nights.summarize(child, days, entries)
  end

  @doc """
  Today's whole sleep day and what to do about it: the ordered schedule from
  `Trygg.Reports.DayPlan` (what happened, what's running, what's predicted
  from the current conditions) and the insights and suggestions from
  `Trygg.Sleep.Coach`, plus this week's `Trygg.Reports.SleepHabits`.

  Options: `:last_feed_at` (a `DateTime`, to nudge a feed during a long nap).
  Requires `:viewer`.
  """
  def sleep_plan(%Scope{} = scope, %Child{} = child, now \\ DateTime.utc_now(), opts \\ []) do
    Families.authorize!(scope, child, :viewer)
    now = DateTime.truncate(now, :second)

    s = summary(scope, child, @outlook_window, now)
    habits = sleep_habits(scope, child, now)
    phase = Trygg.Sleep.Phase.for_child(child)

    nights = nights(scope, child, now)

    context = %{
      child: child,
      phase: phase,
      prediction: s.prediction,
      today: s.today,
      habits: habits,
      nights: nights,
      last_feed_at: opts[:last_feed_at],
      now: now
    }

    %{
      plan: DayPlan.build(child, s.today, s.prediction, now),
      insights: Trygg.Sleep.Coach.insights(context),
      habits: habits,
      nights: nights,
      phase: phase,
      prediction: s.prediction,
      today: s.today
    }
  end

  @doc """
  Sleep cues and the feed-to-sleep pattern over the last
  7 local days, for the Home Sleep plan card. See
  `Trygg.Reports.SleepHabits`. Requires `:viewer`.
  """
  def sleep_habits(%Scope{} = scope, %Child{} = child, now \\ DateTime.utc_now()) do
    Families.authorize!(scope, child, :viewer)
    now = DateTime.truncate(now, :second)
    today = Child.local_today(child)
    {start, _} = Child.day_bounds(child, Date.add(today, 1 - SleepHabits.window_days()))
    since = DateTime.add(start, -SleepHabits.lookback_seconds(), :second)

    entries =
      Log.list_entries(scope, child, types: [:sleep, :feeding, :breastfeeding], since: since)

    SleepHabits.summarize(child, entries, today, now)
  end

  @doc """
  Just the growth-burst signal from `Trygg.Reports.Shifts` (for the Vitals
  screen, which doesn't need the rest of the summary).
  """
  def growth_burst(%Scope{} = scope, %Child{} = child, now \\ DateTime.utc_now()) do
    Families.authorize!(scope, child, :viewer)
    today = Child.local_today(child)
    days = days_unchecked(scope, child, Date.add(today, 1 - @shift_days), today, now)
    Shifts.summarize(days, Feeding.summarize(child, days, now)).growth_burst
  end

  defp recent_weight(scope, child) do
    case Growth.latest_weight(scope, child) do
      %{weight_g: g, measured_at: %DateTime{} = at} when is_number(g) ->
        %{grams: g, date: at |> DateTime.shift_zone!(child.timezone) |> DateTime.to_date()}

      _ ->
        nil
    end
  end

  defp window_start(_scope, _child, today, n) when is_integer(n) and n > 0 do
    Date.add(today, 1 - n)
  end

  defp window_start(scope, child, today, :all) do
    cap = Date.add(today, -364)
    floor = Date.add(today, -6)

    case Log.oldest_started_at(scope, child) do
      nil ->
        floor

      %DateTime{} = dt ->
        date = dt |> DateTime.shift_zone!(child.timezone) |> DateTime.to_date()
        date = if Date.before?(date, cap), do: cap, else: date
        if Date.before?(date, floor), do: date, else: floor
    end
  end

  defp days_unchecked(scope, child, from_date, to_date, now),
    do: scope |> load_days(child, from_date, to_date, now) |> elem(0)

  # The `%Day{}`s from `from_date` through `to_date` and the entries they were
  # built from (the window plus the lookback before it), for callers that need
  # both.
  defp load_days(scope, child, from_date, to_date, now) do
    now = DateTime.truncate(now, :second)
    {start, _} = Child.day_bounds(child, from_date)
    {_, finish} = Child.day_bounds(child, to_date)
    since = DateTime.add(start, -@lookback_hours * 3600, :second)

    entries = Log.list_entries(scope, child, since: since, until: finish)

    days =
      from_date
      |> Date.range(to_date)
      |> Enum.map(&Day.build(child, &1, entries, now))

    {days, entries}
  end
end
