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
  What the log can say about the first three conventions. `ctx` is
  `%{child, days}`: `days` are recent `%Trygg.Reports.Day{}`s, from which the
  naps (and the place noted on each, `data["location"]`) and bedtimes come.

  Returns `%{place, catnaps}`:

    * `place` — `nil` without 5 naps with a place noted, else `%{share, where,
      count, ok?}`: the share of naps in the most common place and whether it
      meets the 80% goal.
    * `catnaps` — `%{days, ok?}`: how many of the recent days had a nap ending
      within 90 minutes of bedtime (a nap that late works against bedtime).
  """
  def assess(%{child: %Child{} = child} = ctx) do
    days = ctx[:days] || []
    entries = days |> Enum.flat_map(& &1.naps) |> Enum.map(& &1.entry)
    %{place: place(entries), catnaps: catnaps(child, days)}
  end

  defp place(naps) do
    located = for nap <- naps, loc = nap.data["location"], is_binary(loc), do: loc

    if length(located) < 5 do
      nil
    else
      {where, count} = located |> Enum.frequencies() |> Enum.max_by(&elem(&1, 1))
      share = count / length(located)
      %{share: share, where: where, count: length(located), ok?: share >= 0.8}
    end
  end

  defp catnaps(child, days) do
    late =
      Enum.count(days, fn day ->
        day.bedtime != nil and
          Enum.any?(day.naps, fn nap ->
            not nap.running? and nap.end != nil and
              DateTime.diff(day.bedtime, nap.end, :second) in 0..(90 * 60)
          end)
      end)

    _ = child
    %{days: late, ok?: late <= 1}
  end
end
