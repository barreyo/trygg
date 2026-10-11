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
  alias Trygg.Reports.FallingAsleep
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
  How the child's way of falling asleep has changed over the last six weeks
  (`Trygg.Reports.FallingAsleep`). Requires `:viewer`.
  """
  def falling_asleep(%Scope{} = scope, %Child{} = child, _now \\ DateTime.utc_now()) do
    Families.authorize!(scope, child, :viewer)
    today = Child.local_today(child)
    {start, _} = Child.day_bounds(child, Date.add(today, -(FallingAsleep.weeks() * 7 - 1)))
    entries = Log.list_entries(scope, child, type: :sleep, since: start)
    FallingAsleep.summarize(child, entries, today)
  end

  @doc """
  How the last few nights went (`Trygg.Reports.Nights`): bedtime and wake,
  sleep, wakings, the longest unbroken sleep and the longest stretch between
  feeds. Requires `:viewer`.
  """
  def nights(%Scope{} = scope, %Child{} = child, now \\ DateTime.utc_now(), opts \\ []) do
    Families.authorize!(scope, child, :viewer)
    today = Child.local_today(child)
    count = Keyword.get(opts, :count, Nights.count())
    # One more day than the nights shown: each night needs the morning after it.
    {days, entries} = load_days(scope, child, Date.add(today, -count), today, now)
    Nights.summarize(child, days, entries, count: count)
  end

  @doc """
  What the Sleep plan page shows: whether "The ABCs of Sleep"
  (`Trygg.Sleep.Abcs`) can start and what's missing, and while it's running
  tonight's instructions, the night-by-night chart and progress, plus the nap
  training signs and the age's day shape. Requires `:viewer`.
  """
  def sleep_training(%Scope{} = scope, %Child{} = child, now \\ DateTime.utc_now()) do
    Families.authorize!(scope, child, :viewer)
    now = DateTime.truncate(now, :second)
    today = Child.local_today(child)

    phase = Trygg.Sleep.Phase.for_child(child)
    plan = Trygg.Sleep.Plans.active(scope, child)
    nights = nights(scope, child, now, count: 14)
    s = summary(scope, child, @outlook_window, now)

    nap_medians =
      for %{median: median} when is_number(median) <- s.naps.by_ordinal, do: median

    table = phase && Trygg.Sleep.Schedules.for_age(phase.age_days)

    base = %{
      phase: phase,
      eligibility: Trygg.Sleep.Plans.eligibility(child, phase, today),
      plan: plan,
      setup: suggest_setup(child, nights),
      table: table,
      nap_readiness:
        Trygg.Sleep.NapTraining.readiness(%{
          child: child,
          nights: nights,
          nap_medians: nap_medians,
          age_days: phase && phase.age_days
        })
    }

    if plan do
      wakes = Trygg.Sleep.NightWakes.for_plan(scope, plan)
      plan_nights = Trygg.Reports.PlanNights.build(child, plan, wakes, nights, now)

      Map.merge(base, %{
        tonight: Trygg.Sleep.Plans.tonight(plan, child, now),
        weaning_table: Trygg.Sleep.Plans.weaning_table(plan),
        plan_nights: plan_nights,
        progress: Trygg.Reports.PlanNights.progress(plan_nights)
      })
    else
      base
    end
  end

  # Night feeds to wean, from the last night: the feeds outside the dream-feed
  # window, up to three, with their times (minutes after local midnight) and
  # amounts (ml for a bottle, minutes for nursing). `nil` with no night feeds.
  defp suggest_setup(child, nights) do
    {dream_from, dream_to} = Trygg.Sleep.NightFeeds.dream_feed_window()

    with %{feed_events: [_ | _] = events} <- nights.last do
      feeds =
        for event <- events,
            local = DateTime.shift_zone!(event.at, child.timezone),
            minutes = local.hour * 60 + local.minute,
            not (minutes >= dream_from and minutes <= dream_to),
            amount = event.ml || event.minutes,
            is_number(amount) and amount > 0 do
          {minutes, round(amount), event.kind}
        end
        |> Enum.take(3)

      case feeds do
        [] ->
          nil

        [{_, _, kind} | _] ->
          %{
            kind: if(kind == :feeding, do: :bottle, else: :nursing),
            feeds: Enum.map(feeds, fn {time, amount, _} -> {time, amount} end)
          }
      end
    else
      _ -> nil
    end
  end

  @doc """
  Everything the Sleep toolkit page shows for the 13-week stage: how they fall
  asleep, the bedtime plan and the guide's day, the night-feed plan with its
  gates, and the checklists. Requires `:viewer`.

  Options: `:last_feed_at` (a `DateTime`).
  """
  def sleep_toolkit(%Scope{} = scope, %Child{} = child, now \\ DateTime.utc_now(), opts \\ []) do
    Families.authorize!(scope, child, :viewer)
    now = DateTime.truncate(now, :second)
    today = Child.local_today(child)

    phase = Trygg.Sleep.Phase.for_child(child)
    s = summary(scope, child, @outlook_window, now)
    nights = nights(scope, child, now)
    falling = falling_asleep(scope, child, now)
    habits = sleep_habits(scope, child, now)
    growth = Growth.velocity(scope, child)

    table = phase && Trygg.Sleep.Schedules.for_age(phase.age_days)
    usual = s.bedtime && s.bedtime.median_minutes && round(s.bedtime.median_minutes)

    wake_at =
      s.today.morning_wake ||
        (s.morning_wake && s.morning_wake.median_minutes &&
           Child.at_local(child, today, minutes_to_time(s.morning_wake.median_minutes))) ||
        Child.at_local(child, today, ~T[07:00:00])

    gates = Trygg.Sleep.NightFeeds.gates(child, phase || %{age_days: 0, next: nil}, growth, today)

    %{
      phase: phase,
      table: table,
      falling_asleep: falling,
      bedtime_plan: table && Trygg.Sleep.BedtimePlan.build(table, usual),
      guide_day: table && Trygg.Sleep.Schedules.plan_day(child, table, wake_at),
      nights: nights,
      night_wakes:
        Trygg.Sleep.NightWakes.summarize(Trygg.Sleep.NightWakes.recent(scope, child, 14)),
      night_feed_gates: gates,
      night_feed_plan: Trygg.Sleep.NightFeeds.plan(child, nights, opts[:last_feed_at], now),
      night_feed_typical: Trygg.Sleep.NightFeeds.typical(phase && phase.age_days),
      power_tools: Trygg.Sleep.PowerTools.plan(phase && phase.age_days, child.sleep_checks),
      safe_sleep: Trygg.Sleep.SafeSleep.evaluate(child.sleep_checks),
      checklists:
        Trygg.Sleep.Checklists.evaluate(%{
          child: child,
          nights: nights,
          falling_asleep: falling,
          habits: habits
        })
    }
  end

  defp minutes_to_time(minutes) do
    minutes = round(minutes)
    Time.new!(rem(div(minutes, 60), 24), rem(minutes, 60), 0)
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

    age_days = phase && phase.age_days
    band = Trygg.Sleep.AgeGuide.band(age_days)

    %{
      plan: DayPlan.build(child, s.today, s.prediction, now),
      insights: Trygg.Sleep.Coach.insights(context),
      habits: habits,
      nights: nights,
      phase: phase,
      prediction: s.prediction,
      today: s.today,
      age_guide: %{
        band: band,
        wake_time: Trygg.Sleep.AgeGuide.wake_time(age_days),
        comparison: Trygg.Sleep.AgeGuide.compare(band, Trygg.Sleep.AgeGuide.stats_from(s))
      }
    }
  end

  @doc """
  What the Sleep playbooks page shows: what the log says is worth a look
  (`Trygg.Reports.Setbacks`), how the naps measure up against the book's
  conventions, the next clock change, and the child's usual bedtime and wake
  time to start the planners from. Requires `:viewer`.
  """
  def sleep_playbooks(%Scope{} = scope, %Child{} = child, now \\ DateTime.utc_now()) do
    Families.authorize!(scope, child, :viewer)
    now = DateTime.truncate(now, :second)
    today = Child.local_today(child)

    phase = Trygg.Sleep.Phase.for_child(child)
    age_days = phase && phase.age_days
    s = summary(scope, child, @outlook_window, now)
    nights = nights(scope, child, now, count: 14)
    {days, _entries} = load_days(scope, child, Date.add(today, -13), today, now)

    %{
      phase: phase,
      age_days: age_days,
      findings:
        Trygg.Reports.Setbacks.detect(%{
          child: child,
          age_days: age_days,
          nights: nights,
          days: days,
          insights: s,
          today: today
        }),
      naps: Trygg.Sleep.NapConventions.assess(%{child: child, days: days}),
      dst: Trygg.Sleep.Setbacks.next_dst_change(child, today),
      usual: %{
        bed: s.bedtime && s.bedtime.median_minutes && round(s.bedtime.median_minutes),
        wake:
          s.morning_wake && s.morning_wake.median_minutes && round(s.morning_wake.median_minutes)
      },
      power_tools: Trygg.Sleep.PowerTools.plan(age_days, child.sleep_checks),
      drop: Trygg.Sleep.NapConventions.drop_for(age_days)
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
