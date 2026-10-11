defmodule Trygg.Reports.Setbacks do
  @moduledoc """
  Things worth a look in the last week or two, spotted in the log and pointed at
  the matching playbook in `Trygg.Sleep.Setbacks`: very early mornings, a long
  wake in the night, short naps, sleep debt, late catnaps, a drifting bedtime, a
  nap that's ready to go, a regression window, a clock change coming.

  Nothing here says something is wrong. Each finding says what the log shows and
  what the book would try. Pure: takes the child, their corrected age, and the
  summaries it needs.
  """

  alias Trygg.Families.Child
  alias Trygg.Reports.Stats
  alias Trygg.Sleep.{AgeGuide, NapConventions, Setbacks}

  # Findings need history, and only apply once the newborn stage is over.
  @min_age_days 91
  @recent_nights 7
  @early_wake_minutes 5 * 60 + 30
  @night_gap_seconds 3600
  @short_nap_seconds 45 * 60
  @min_naps 8
  @bedtime_spread_minutes 30
  @dst_notice_days 10

  @doc """
  The findings for `ctx`:

      %{child, age_days, nights, days, insights, today}

  where `nights` is a `Trygg.Reports.Nights` summary, `days` the recent
  `%Day{}`s (oldest first), `entries` the log entries they were built from and
  `insights` a `Trygg.Reports.Insights` summary.
  Each finding is `%{id, title, detail, playbook, points}`; `playbook` is a
  `Trygg.Sleep.Setbacks` id or `nil`, `points` a short list of what to try when there's no playbook. Most pressing first.
  """
  def detect(%{child: %Child{} = child, today: today} = ctx) do
    age = ctx[:age_days]

    [
      dst(child, today),
      early_wake(child, age, ctx.nights),
      night_gap(age, ctx.nights),
      sleep_debt(age, ctx.days),
      late_catnap(child, age, ctx),
      short_naps(age, ctx.days),
      nap_drop(age, ctx.days),
      bedtime_drift(age, ctx.insights),
      # Informational, so it goes last.
      regression(age)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Map.put_new(&1, :points, []))
  end

  defp dst(child, today) do
    case Setbacks.next_dst_change(child, today) do
      %{date: date, direction: direction} ->
        days = Date.diff(date, today)

        if days <= @dst_notice_days do
          %{
            id: :dst,
            title: "The clocks go #{direction_word(direction)} in #{days_word(days)}",
            detail:
              "Spring is easier if you start early: 15 minutes a day for four days. Autumn is about light. The clock-change planner in Help has the days.",
            playbook: nil,
            points:
              direction
              |> Setbacks.dst_plan(date, %{bed: 19 * 60, wake: 6 * 60})
              |> Map.fetch!(:tips)
              |> Enum.take(3)
          }
        end

      nil ->
        nil
    end
  end

  defp direction_word(:forward), do: "forward"
  defp direction_word(:back), do: "back"

  defp days_word(0), do: "less than a day"
  defp days_word(1), do: "a day"
  defp days_word(n), do: "#{n} days"

  defp regression(age) do
    case Setbacks.regression_window(age) do
      {months, to_go} ->
        %{
          id: :regression_window,
          title: "Around the #{months}-month mark",
          detail:
            if(to_go >= 0,
              do:
                "A common time for a rough week or two (it's #{to_go} days off). If sleep falls apart, hold on to independent sleep and do what works for a few days.",
              else:
                "A common time for a rough week or two, and it's #{-to_go} days past. If sleep is worse, it may be that, and it passes."
            ),
          playbook: :regression
        }

      nil ->
        nil
    end
  end

  defp early_wake(_child, age, _nights) when not is_integer(age) or age < @min_age_days, do: nil

  defp early_wake(child, _age, %{nights: nights}) do
    recent = Enum.take(nights, @recent_nights)

    early =
      Enum.count(recent, fn night ->
        local = DateTime.shift_zone!(night.wake, child.timezone)
        local.hour * 60 + local.minute < @early_wake_minutes
      end)

    if early >= 3 do
      %{
        id: :early_wake,
        title: "Mornings are starting early",
        detail:
          "#{early} of the last #{length(recent)} mornings began before 5:30. Check how long they're awake before bed first, and light and noise before changing anything.",
        playbook: :early_morning
      }
    end
  end

  defp night_gap(age, _nights) when not is_integer(age) or age < @min_age_days, do: nil

  defp night_gap(_age, %{nights: nights}) do
    recent = Enum.take(nights, @recent_nights)
    gaps = Enum.count(recent, &(&1.longest_waking_seconds >= @night_gap_seconds))

    if gaps >= 3 do
      %{
        id: :night_gap,
        title: "Long wakes in the night",
        detail:
          "On #{gaps} of the last #{length(recent)} nights they were up for an hour or more. If how they fall asleep and what you do at night are sorted, it can be that they're sleeping more in total than they need.",
        playbook: :night_gap
      }
    end
  end

  defp sleep_debt(age, _days) when not is_integer(age), do: nil

  defp sleep_debt(age, days) do
    band = AgeGuide.band(age)
    complete = days |> Enum.reject(& &1.now?) |> Enum.filter(&(&1.total_sleep_seconds > 0))
    last = Enum.take(complete, -3)

    with %{total_hours: {lo, _hi}} <- band,
         true <- length(last) == 3,
         avg = Enum.sum(Enum.map(last, & &1.total_sleep_seconds)) / 3 / 3600,
         true <- avg < lo - 1 do
      %{
        id: :sleep_debt,
        title: "Behind on sleep",
        detail:
          "The last three days averaged #{Float.round(avg, 1)} hours, under the #{lo}–#{elem(band.total_hours, 1)} the book gives for this age. Try bedtime 30 minutes earlier for a few days to catch up.",
        playbook: :sleep_debt
      }
    else
      _ -> nil
    end
  end

  defp late_catnap(_child, age, _ctx) when not is_integer(age) or age < @min_age_days, do: nil

  defp late_catnap(child, age, ctx) do
    with %{before_bed: {min, _max}} <- AgeGuide.band(age),
         %{catnaps: %{days: late}} when late >= 3 <-
           NapConventions.assess(%{
             child: child,
             entries: ctx[:entries] || [],
             today: ctx.today,
             min_window_minutes: min
           }) do
      %{
        id: :late_catnap,
        title: "Not much time awake before bed",
        detail:
          "On #{late} of the last 7 evenings the last nap ended less than #{min} minutes before they went down for the night. A late catnap, even a short one in the car, eats the build-up to bedtime.",
        playbook: nil,
        points: [
          "Cap the afternoon nap, or wake them from it sooner, so it ends at least #{min} minutes before bed.",
          "No car or stroller naps late in the day: even five minutes deflates the build-up to bedtime.",
          "If a late nap can't be avoided, push bedtime later that night rather than putting them down too soon."
        ]
      }
    else
      _ -> nil
    end
  end

  defp short_naps(age, _days) when not is_integer(age) or age < 122, do: nil

  defp short_naps(_age, days) do
    naps = days |> Enum.flat_map(& &1.naps) |> Enum.reject(& &1.running?)
    # The last nap of a day is often a short one on purpose.
    firsts = Enum.reject(naps, &(&1.ordinal >= 3))

    if length(firsts) >= @min_naps and
         Stats.median(Enum.map(firsts, & &1.seconds)) < @short_nap_seconds do
      %{
        id: :short_naps,
        title: "Naps are short",
        detail:
          "The first two naps of the day run under 45 minutes. If they fall asleep on their own, the book has two tricks for stretching them.",
        playbook: nil,
        points: for(fix <- NapConventions.short_nap_fixes(), do: "#{fix.name}. #{fix.detail}")
      }
    end
  end

  defp nap_drop(age, _days) when not is_integer(age) or age < 182, do: nil

  defp nap_drop(age, days) do
    counts = days |> Enum.reject(& &1.now?) |> Enum.map(&length(&1.naps)) |> Enum.take(-7)

    third =
      days
      |> Enum.flat_map(& &1.naps)
      |> Enum.filter(&(&1.ordinal == 3 and not &1.running?))
      |> Enum.map(& &1.seconds)

    if age < 365 and length(counts) >= 5 and Stats.median(counts) >= 3 and length(third) >= 3 and
         Stats.median(third) < 30 * 60 do
      %{
        id: :nap_drop,
        title: "The third nap is getting thin",
        detail:
          "It's often under half an hour now. Between six and twelve months the third nap goes. Skip it when the second runs late or long, or bridge to bedtime with a walk.",
        playbook: nil,
        points: NapConventions.transition_tips()
      }
    end
  end

  defp bedtime_drift(age, _insights) when not is_integer(age) or age < @min_age_days, do: nil

  defp bedtime_drift(_age, %{bedtime: %{iqr_minutes: iqr}}) when is_number(iqr) do
    if iqr > @bedtime_spread_minutes do
      %{
        id: :bedtime_drift,
        title: "Bedtime moves around",
        detail:
          "It varies by about #{round(iqr)} minutes. From three months a steady bedtime, within 15–30 minutes, is one of the strongest sleep cues there is.",
        playbook: nil,
        points: [
          "Pick a time, usually between 7 and 8 pm, and hold it within 15–30 minutes, weekends too.",
          "Plan the naps backwards from it, so they're ready for bed at that time.",
          "To move it, 15 minutes a day. The bedtime planner in Help has the days."
        ]
      }
    end
  end

  defp bedtime_drift(_age, _insights), do: nil
end
