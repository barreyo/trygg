defmodule Trygg.Sleep.NapConventions do
  @moduledoc """
  Naps, from *Precious Little Sleep*'s chapter on them: the four conventions, how
  many naps at each age and when they go, how to stretch short ones, and what to
  do when a nap is dropped.

  `assess/1` checks what the log can say about the first three conventions
  (same place and cues, timing, no catnaps near bedtime); the rest is advice.
  Wording is ours and the numbers follow the book. Everything is a guide: the
  child's own pattern wins.
  """

  alias Trygg.Families.Child

  @conventions [
    %{
      id: :soothing,
      name: "Age-appropriate soothing",
      detail:
        "Use the power tools for their age (sound, swaddle while it's safe, pacifier). Naps need more help than bedtime, and that's fine. Nap and night don't have to match."
    },
    %{
      id: :consistency,
      name: "Consistency",
      detail:
        "Same place, same short routine (10–15 minutes from about two months), same cues, about 80% of the time. Once they're no longer newborns, napping at home matters."
    },
    %{
      id: :timing,
      name: "Timing",
      detail:
        "Not awake too long and not too short. Early is better than late. Count the time awake from the last wake-up when sleepy cues are unreliable."
    },
    %{
      id: :independent,
      name: "Independent sleep (from 3–6 months)",
      detail:
        "They have to learn to fall asleep alone twice: once for bedtime and once for naps. It's the biggest thing between you and good naps, and it's easier once bedtime is sorted."
    }
  ]

  # Nap-dropping milestones, by corrected age in days.
  @drops [
    %{
      from_days: 91,
      label: "3–6 months",
      text:
        "Down to three or four by three months and to three by four to six. Usually painless, and bedtime moves earlier."
    },
    %{
      from_days: 182,
      label: "6–12 months",
      text:
        "The third nap goes, anywhere from six to twelve months (earlier with long naps). It often becomes an on-the-go one first. Skip it if nap two is late or long; otherwise a short walk to bridge to bedtime beats being awake too long."
    },
    %{
      from_days: 365,
      label: "12–18 months",
      text:
        "From two naps to one, between a year and eighteen months. Often messy for weeks. Don't assume a rough couple of days means it's time before their first birthday."
    },
    %{
      from_days: 548,
      label: "18 months–3 years",
      text:
        "Most are still napping at three. Don't confuse not wanting a nap with not needing one."
    },
    %{
      from_days: 1095,
      label: "3–5 years",
      text:
        "Most stop between three and five. When they do, move to an hour of quiet time with a few board books and a timer or clock to say when it's over."
    }
  ]

  @drop_signs [
    "Afternoon or evening naps make bedtime hard.",
    "Naptime has turned into a battle.",
    "Long naps have become short ones.",
    "The morning nap is fine but the afternoon one won't happen (or the other way round).",
    "They fall asleep fine but are awake for a long stretch in the night.",
    "The morning wake-up is creeping earlier."
  ]

  @transition_tips [
    "A catnap can take the edge off: or it can wreck the evening. Try both.",
    "Move the whole day, naps and bedtime, earlier for a while.",
    "Shorten the nap that's on its way out rather than dropping it dead.",
    "Go outside at the old nap time: bright light and a distraction.",
    "Some children go to a nap every other day on the way out."
  ]

  @short_nap_fixes [
    %{
      id: :disrupt,
      name: "Disrupt the sleep cycle",
      detail:
        "Short naps are usually clockwork. Five to ten minutes before they normally wake, gently jostle them in the crib until you see their eyes flutter, not enough for them to wait for you to pick them up. Do it for 5–7 days."
    },
    %{
      id: :bore,
      name: "Bore them back to sleep",
      detail:
        "After a nap under 30 minutes, leave them in the quiet, dull, dark room for 15–30 minutes and see whether they drop back off. First two naps of the day only. If they complain the whole time for weeks, give up gracefully."
    }
  ]

  # The book's "Nap Master Plan" for teaching independent sleep at naps, once
  # bedtime is sorted.
  @master_plan [
    %{
      name: "Pick the plan",
      detail:
        "Use the one that worked at bedtime. If bedtime was a mess, go straight to the sleep learning plan. If you started with sleep learning, you can carry on with it or try a gradual plan for naps. If you begin naps with sleep learning, you're committed."
    },
    %{
      name: "Commit for five days",
      detail:
        "Start with the first nap. Do the wind-down routine and your plan for up to an hour. If they fall asleep, let them sleep as long as they like (but wake them if it would spoil the next nap). If they nap for a bit and wake, naptime is over: a micro-nap is a win. If an hour passes and they haven't slept, get up and try again at the next nap. No feeding, rocking or stroller naps to rescue it. For the third nap, an outing is fine, but not whatever you're weaning off."
    },
    %{
      name: "Judge by the trend",
      detail:
        "Keep notes. You're looking for less help or fewer tears than on day one, longer naps than on day one, and any independent sleep at all. A full week with no sleep at all, or a gut feeling that it's wrong, means rethink. Expect it to take longer than bedtime: daytime sleep drive is small. Move bedtime 30–60 minutes earlier on days with no naps."
    }
  ]

  @doc "The Nap Master Plan: three steps."
  def master_plan, do: @master_plan

  @doc "The four conventions."
  def conventions, do: @conventions

  @doc "The nap-dropping milestones, youngest first."
  def drops, do: @drops

  @doc "The signs a nap is on its way out."
  def drop_signs, do: @drop_signs

  @doc "What to do while a nap is on its way out."
  def transition_tips, do: @transition_tips

  @doc "The two ways to stretch a short nap."
  def short_nap_fixes, do: @short_nap_fixes

  @doc """
  The drop milestone for a corrected age in days: the latest one at or before
  `age_days`, or `nil` before three months.
  """
  def drop_for(age_days) when is_integer(age_days),
    do: @drops |> Enum.filter(&(&1.from_days <= age_days)) |> List.last()

  def drop_for(_), do: nil

  @doc """
  What the log can say about the conventions, from the sleep entries of the last
  couple of weeks. `ctx` is `%{child, entries, today, min_window_minutes}`:
  `entries` are the child's entries (only the sleeps count), `today` the local
  date, and `min_window_minutes` how long they should be awake before bedtime at
  this age (`Trygg.Sleep.AgeGuide`; `nil` to skip that check).

  Returns `%{place, catnaps}`:

    * `place` — `nil` without 5 daytime sleeps with a place noted, else `%{share,
      where, count, ok?}`: the share in the most common place and whether it meets
      the 80% goal.
    * `catnaps` — `%{days, ok?}`: on how many of the last 7 evenings the nap
      before bed ended with less than `min_window_minutes` to go to the night's
      sleep. Read from the entries, not from `Trygg.Reports.Day`, because a nap
      that close to bed is folded into the night there.
  """
  def assess(%{child: %Child{} = child} = ctx) do
    sleeps = for e <- ctx[:entries] || [], e.type == :sleep, e.ended_at != nil, do: e

    %{
      place: place(child, sleeps),
      catnaps: catnaps(child, sleeps, ctx[:today], ctx[:min_window_minutes])
    }
  end

  # Daytime sleeps are the ones that start between 6 am and 6 pm.
  defp place(child, sleeps) do
    located =
      for sleep <- sleeps,
          hour = local(child, sleep.started_at).hour,
          hour in 6..17,
          loc = sleep.data["location"],
          is_binary(loc),
          do: loc

    if length(located) < 5 do
      nil
    else
      {where, count} = located |> Enum.frequencies() |> Enum.max_by(&elem(&1, 1))
      share = count / length(located)
      %{share: share, where: where, count: length(located), ok?: share >= 0.8}
    end
  end

  defp catnaps(_child, _sleeps, _today, nil), do: %{days: 0, ok?: true}
  defp catnaps(_child, _sleeps, nil, _min), do: %{days: 0, ok?: true}

  defp catnaps(child, sleeps, today, min_minutes) do
    by_date = Enum.group_by(sleeps, &(local(child, &1.started_at) |> DateTime.to_date()))

    short =
      Enum.count(1..7, fn back ->
        day = Map.get(by_date, Date.add(today, 1 - back), [])
        short_window?(child, day, min_minutes)
      end)

    %{days: short, ok?: short <= 1}
  end

  # The night's sleep starts after 5:30 pm and runs at least 90 minutes; the nap
  # before it is the last daytime sleep to end before that.
  defp short_window?(child, day, min_minutes) do
    night =
      day
      |> Enum.filter(fn s ->
        local = local(child, s.started_at)
        local.hour * 60 + local.minute >= 17 * 60 + 30 and duration(s) >= 90 * 60
      end)
      |> Enum.min_by(& &1.started_at, DateTime, fn -> nil end)

    with %{started_at: bed} <- night,
         %{ended_at: ended} <-
           day
           |> Enum.filter(
             &(DateTime.compare(&1.ended_at, bed) != :gt and duration(&1) < 3 * 3600)
           )
           |> Enum.filter(&(local(child, &1.started_at).hour >= 10))
           |> Enum.max_by(& &1.ended_at, DateTime, fn -> nil end) do
      DateTime.diff(bed, ended, :second) < min_minutes * 60
    else
      _ -> false
    end
  end

  defp duration(sleep), do: DateTime.diff(sleep.ended_at, sleep.started_at, :second)
  defp local(child, at), do: DateTime.shift_zone!(at, child.timezone)
end
