defmodule Trygg.Sleep.Coach do
  @moduledoc """
  Plain-language insights and suggestions for the Sleep tab, from the child's
  current conditions: how long they've been awake against their usual window,
  a running nap, how short the day's sleep is, the cues noted this week and the
  feed → sleep pattern.

  Each is `%{id, tone, title, detail}` where `tone` is `:watch`, `:suggest` or
  `:info`, most pressing first. Same copy rules as `Trygg.Reports.Alerts`: no
  diagnoses, say what we see and what the guidance suggests. Guidance comes from
  the Taking Cara Babies guides.

  Pure: `insights/1` takes a map with `:child`, `:phase`, `:prediction`,
  `:today` (a `%Day{}`), `:habits` (`Trygg.Reports.SleepHabits`), `:nights`
  (`Trygg.Reports.Nights`, optional), `:last_feed_at`
  (a `DateTime` or `nil`) and `:now`.
  """

  alias Trygg.Families.Child

  @max_insights 6
  @tone_rank %{watch: 0, suggest: 1, info: 2}

  # Newborn guidance: offer a feed about every 2.5–3 hours, so after 3 hours a
  # sleeper can be woken for one.
  @feed_gap_seconds 3 * 3600
  # 3–4 month guidance: wake a nap at 2 hours, keep the day under 5 hours of naps.
  @long_nap_seconds 2 * 3600
  @daytime_cap_seconds 5 * 3600
  @bedtime_shift_floor 10 * 60
  @late_bedtime_minutes 20 * 60 + 15

  @doc "Insights for the current moment, most pressing first (at most #{@max_insights})."
  def insights(%{} = ctx) do
    [
      pressure(ctx),
      feed_due(ctx),
      long_nap(ctx),
      daytime_cap(ctx),
      bedtime_shifted(ctx),
      late_bedtime(ctx),
      overtired_pattern(ctx),
      cue_window(ctx),
      longest_night(ctx),
      feed_sleep(ctx),
      transition(ctx),
      estimates(ctx)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&@tone_rank[&1.tone])
    |> Enum.take(@max_insights)
  end

  ## Rules -------------------------------------------------------------------

  defp pressure(ctx) do
    if asleep_nap?(ctx), do: nil, else: awake_pressure(ctx)
  end

  defp awake_pressure(%{prediction: %{state: :awake, wake_pressure: %{state: :past} = wp}} = ctx) do
    insight(
      "past-window",
      :watch,
      "Past their usual time awake",
      "Awake #{dur(wp.awake_seconds)} against a usual #{dur(wp.typical_seconds)}. " <>
        "Overtired babies often look wired, not sleepy: dim the room and settle them now." <>
        cries(ctx)
    )
  end

  defp awake_pressure(
         %{prediction: %{state: :awake, wake_pressure: %{state: :approaching} = wp}} = ctx
       ) do
    insight(
      "nap-window",
      :suggest,
      "Nap window is open",
      "Awake #{dur(wp.awake_seconds)}; they're usually ready around #{dur(wp.typical_seconds)}. " <>
        "Start settling at the first sleepy cues." <> ready_hint(ctx)
    )
  end

  defp awake_pressure(_ctx), do: nil

  defp feed_due(%{phase: %{id: :newborn}, last_feed_at: %DateTime{} = fed, now: now} = ctx) do
    gap = DateTime.diff(now, fed, :second)

    if asleep_nap?(ctx) and gap >= @feed_gap_seconds and daytime?(ctx) do
      insight(
        "feed-due",
        :suggest,
        "A feed may be due",
        "It's been #{dur(gap)} since the last feed. The guidance is a feed about every " <>
          "2.5–3 hours, so a gentle wake for one is fine."
      )
    end
  end

  defp feed_due(_ctx), do: nil

  defp long_nap(%{phase: %{id: id}} = ctx) when id != :newborn do
    with %{seconds: seconds} when seconds >= @long_nap_seconds <- running_nap(ctx) do
      insight(
        "long-nap",
        :suggest,
        "This nap is past 2 hours",
        "Asleep #{dur(seconds)}. Waking gently keeps the day's sleep in balance and protects bedtime."
      )
    else
      _ -> nil
    end
  end

  defp long_nap(_ctx), do: nil

  defp daytime_cap(%{phase: %{id: id}, today: today}) when id != :newborn do
    if (today.day_sleep_seconds || 0) > @daytime_cap_seconds do
      insight(
        "daytime-cap",
        :watch,
        "Lots of daytime sleep",
        "Over 5 hours of daytime sleep so far. More than that can make night sleep harder: " <>
          "consider waking from the next nap at 2 hours."
      )
    end
  end

  defp daytime_cap(_ctx), do: nil

  defp bedtime_shifted(%{prediction: %{bedtime: %{shifted_by_seconds: shift} = bed}})
       when is_integer(shift) and shift >= @bedtime_shift_floor do
    insight(
      "bedtime-earlier",
      :suggest,
      "Bedtime may come earlier tonight",
      "There's less daytime sleep than usual, so bedtime is estimated around #{bed.label}, " <>
        "about #{div(shift, 60)} minutes earlier than the usual pattern."
    )
  end

  defp bedtime_shifted(_ctx), do: nil

  defp late_bedtime(
         %{phase: %{id: :foundations}, prediction: %{bedtime: %{at: at, label: label}}} = ctx
       ) do
    if local_minutes(ctx.child, at) > @late_bedtime_minutes do
      insight(
        "late-bedtime",
        :suggest,
        "Bedtime is later than the 7–8 pm sweet spot",
        "Estimated #{label}. Moving it earlier by 10–15 minutes each evening works better than a big jump, " <>
          "keeping 100–120 minutes between the last nap and bed."
      )
    end
  end

  defp late_bedtime(_ctx), do: nil

  defp overtired_pattern(%{habits: %{week: %{overtired: n, cued: cued}}} = ctx)
       when n >= 2 and cued >= 3 do
    insight(
      "overtired-pattern",
      :suggest,
      "A few sleeps started overtired",
      "#{n} of #{cued} sleeps with a cue noted this week started overtired. " <>
        "Try settling a little earlier, at the first yawn or stare rather than the first cry." <>
        ready_hint(ctx)
    )
  end

  defp overtired_pattern(_ctx), do: nil

  # Standalone only when the nudges above didn't already say it.
  defp cue_window(%{habits: %{cue_windows: %{"ready" => %{median_seconds: s}}}} = ctx) do
    unless ready_in_other?(ctx) do
      insight(
        "ready-window",
        :info,
        "Their \"ready\" cue",
        "They usually show ready cues after about #{dur(s)} awake: a good moment to start the nap routine." <>
          cue_effect(ctx)
      )
    end
  end

  defp cue_window(_ctx), do: nil

  defp ready_in_other?(%{prediction: %{wake_pressure: %{state: state}}})
       when state in [:approaching],
       do: true

  defp ready_in_other?(%{habits: %{week: %{overtired: n, cued: c}}}), do: n >= 2 and c >= 3
  defp ready_in_other?(_ctx), do: false

  # A new longest unbroken sleep, only once there are a few nights to compare.
  defp longest_night(%{nights: %{nights: [last | earlier]}}) when length(earlier) >= 2 do
    best = earlier |> Enum.map(& &1.longest_sleep_seconds) |> Enum.max()

    if last.longest_sleep_seconds >= best + 15 * 60 do
      insight(
        "longest-night",
        :info,
        "Longest unbroken sleep yet",
        "Last night's longest stretch was #{dur(last.longest_sleep_seconds)}, up from #{dur(best)}."
      )
    end
  end

  defp longest_night(_ctx), do: nil

  defp feed_sleep(%{habits: %{week: %{measured: m, fed_to_sleep: n}}})
       when m >= 4 and n / m >= 0.75 do
    insight(
      "feed-to-sleep",
      :info,
      "Most sleeps start right after a feed",
      "#{n} of #{m} this week. That's normal at this age. When it's easy, try a short awake gap " <>
        "between the feed and sleep, like a diaper change and swaddle."
    )
  end

  defp feed_sleep(_ctx), do: nil

  defp transition(%{prediction: %{transition?: true}}) do
    insight(
      "transition",
      :info,
      "Naps look like they're shifting",
      "The times below are wider than usual while the pattern settles. Follow the cues over the clock."
    )
  end

  defp transition(_ctx), do: nil

  defp estimates(%{child: child, prediction: prediction}) when is_map(prediction) do
    sources = [
      get_in(prediction, [:next_nap, :source]),
      get_in(prediction, [:bedtime, :source])
    ]

    if :age_prior in sources do
      insight(
        "age-estimates",
        :info,
        "Times are typical for their age",
        "Until a few more days of sleep are logged, estimates come from typical patterns for " <>
          "#{child.name}'s age; they'll follow their own rhythm as it appears."
      )
    end
  end

  defp estimates(_ctx), do: nil

  ## Helpers -----------------------------------------------------------------

  defp insight(id, tone, title, detail), do: %{id: id, tone: tone, title: title, detail: detail}

  defp cries(%{phase: %{id: :newborn}}), do: " If they're upset, try C.R.I.E.S."
  defp cries(_ctx), do: ""

  # Say when the cues are pulling predicted nap times, and which way.
  defp cue_effect(%{prediction: %{cue_factor: f}}) when is_number(f) and f <= 0.97,
    do: " Predicted nap times lean about #{round((1 - f) * 100)}% earlier because of it."

  defp cue_effect(%{prediction: %{cue_factor: f}}) when is_number(f) and f >= 1.03,
    do: " Predicted nap times lean about #{round((f - 1) * 100)}% later because of it."

  defp cue_effect(_ctx), do: ""

  defp ready_hint(%{habits: %{cue_windows: %{"ready" => %{median_seconds: s}}}}),
    do: " Their ready cues usually show after about #{dur(s)} awake."

  defp ready_hint(_ctx), do: ""

  defp running_nap(%{today: today}), do: Enum.find(today.naps, & &1.running?)

  defp asleep_nap?(ctx), do: running_nap(ctx) != nil

  defp daytime?(%{child: child, now: now}), do: Child.daytime?(child, now)

  defp local_minutes(child, at) do
    local = DateTime.shift_zone!(at, child.timezone)
    local.hour * 60 + local.minute
  end

  defp dur(nil), do: "a while"

  defp dur(seconds) do
    seconds = round(seconds)
    h = div(seconds, 3600)
    m = rem(div(seconds, 60), 60)

    cond do
      h > 0 and m > 0 -> "#{h}h #{m}m"
      h > 0 -> "#{h}h"
      true -> "#{max(m, 1)}m"
    end
  end
end
