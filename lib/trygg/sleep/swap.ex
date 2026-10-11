defmodule Trygg.Sleep.Swap do
  @moduledoc """
  The "Sleep With Assistance Plans" from *Precious Little Sleep* by Alexis Dubief:
  gradual ways to teach a baby to fall asleep with less and less help from you.
  You pick one, commit to it for five to seven nights, and judge it by the trend.
  Nothing here asks a baby to cry it out, though most babies protest any change
  and a few tears are part of it.

  A variant is `%{id, name, who, summary, steps, nights}` plus `tonight/3`, which
  says what tonight's step is. Gradual ones shrink the help each night:

    * `:jiggle` and `:pat` for babies who need motion (rock, bounce, pat): the
      minutes you do it go down by five a night.
    * `:pull_out` and `:anything_but` for babies who need to suck (feed, pacifier).
    * `:chair` for babies who need your body: you move from touching, to
      present, to a chair that moves two feet further from the crib each night.
    * `:fuss_it_out` and `:double_take` are experiments that don't progress: a
      timed attempt and a gentle half-wake.

  Wording is ours; the numbers follow the book. Not medical advice.
  """

  # Corrected days. A SWAP is for babies past the first couple of months: once
  # the body clock has settled (bedtime predictable, a long stretch after it,
  # falling asleep in 10–15 minutes).
  @min_age_days 61
  @default_nights 7

  # Minutes taken off a motion-based soothe each night.
  @minutes_step 5
  # How much further from the crib the chair sits each night, in feet.
  @chair_step_feet 2

  # {id, text}: what a SWAP asks of you.
  @preflight [
    {"w-circadian",
     "Bedtime is fairly predictable (within about 30 minutes), their longest sleep comes after it, and they fall asleep in 10–15 minutes."},
    {"w-routine", "There's a bedtime routine of 20–30 minutes that we can do every night."},
    {"w-room", "The room is dark, with a sound machine that stays on all night."},
    {"w-tools",
     "We're using the power tools that suit their age: sound, a swaddle if safe, a pacifier if they take one."},
    {"w-commit",
     "We'll stick with this one plan for at least five nights and not slip back to the old way."}
  ]

  @variants [
    %{
      id: :jiggle,
      name: "Jiggle the crib",
      who: "Motion lovers, under about 4 months",
      type: :motion,
      nights: @default_nights,
      summary:
        "Keep rocking or bouncing until they're drowsy, put them in the crib and jiggle it gently until they're asleep. Each night, jiggle for five minutes less.",
      steps: [
        "Rock or bounce until they're drowsy or almost asleep.",
        "Lay them down and jiggle the crib lightly, as close to the motion they like as you can. Shush or use your bedtime words, and avoid eye contact.",
        "Stop at tonight's limit even if they're still grumbling, and walk out.",
        "It can take 20–30 minutes at first. Expect complaints."
      ]
    },
    %{
      id: :pat,
      name: "Pat the back",
      who: "Motion lovers who can stand up in the crib, 6 months and up",
      type: :motion,
      nights: @default_nights,
      summary:
        "A hand on their back or tummy, patting like a drum, so they stay lying down. Each night, pat for five minutes less.",
      steps: [
        "Do the routine, then lay them down awake in the crib.",
        "Pat their back (or tummy if they're rolling over), with your bedtime words.",
        "Stop at tonight's limit and leave, even if they're not quite asleep.",
        "Use the same approach for night wakings: a little less each night."
      ]
    },
    %{
      id: :pull_out,
      name: "Pull-out",
      who: "Babies who feed or suck to sleep, under about 4 months",
      type: :suck,
      nights: @default_nights,
      summary:
        "Let them suck (breast, bottle or pacifier) until calm and drowsy, pop them off and put them down. If they get upset, put it back in, then pop it out again before they're asleep.",
      steps: [
        "Feed or soothe until they're calm and drowsy, not asleep.",
        "Take it out and lay them down in the crib. Mild fussing is fine: leave them.",
        "If they get upset, put it back until they're calm again, then take it out again.",
        "Don't let them fall asleep sucking, even after a long time. That wastes the work.",
        "Once they're falling asleep without it, move the last feed to 15–20 minutes before sleep so sucking and sleeping are apart (feed, bath, pyjamas, books, bed).",
        "If breastfeeding is getting sore, stop: it isn't worth injuring yourself."
      ]
    },
    %{
      id: :anything_but,
      name: "Anything but sucking",
      who: "Babies who feed or suck to sleep: the stepping stone",
      type: :suck,
      nights: @default_nights,
      summary:
        "Separate the last feed from sleep by 20 minutes, then help them sleep with something that isn't sucking: a rub, a pat, shushing, a cuddle. Not yet independent, but a habit that's easier to fade.",
      steps: [
        "Do the last feed or pacifier 20 minutes before they go down.",
        "Help them settle with a back rub, pats, a lovey (if old enough), shushing or a cuddle.",
        "You've turned a sucker into a cuddler or a pat-lover. Fade that with the pat or chair plan next."
      ]
    },
    %{
      id: :chair,
      name: "The chair fade",
      who: "Cuddlers who must be held, up to 6 months",
      type: :cuddle,
      nights: 10,
      summary:
        "First they sleep lying down in the crib with your hand on them, then you're present but quiet, then a chair that moves two feet further away every night until it's out the door.",
      steps: [
        "Nights 1–2: put them down on their back and settle them with touch, patting or a hum. They're asleep in the crib, with you.",
        "Nights 3–4: do less each night (shorter, lighter), until you're only sitting there, quiet.",
        "From night 5: the chair moves two feet farther from the crib and closer to the door every night, until you're out.",
        "If they're used to a particular parent, let the other one do it."
      ]
    },
    %{
      id: :fuss_it_out,
      name: "Fuss it out",
      who: "Most babies over 2 months, as an experiment",
      type: :experiment,
      nights: 5,
      summary:
        "Soothe until calm and drowsy, lay them down awake and walk away for 15–20 minutes. If they settle, you've found the way. If they scream, go back to your usual way and try again another day.",
      steps: [
        "Do the routine and use every age-appropriate tool, then lay them down awake.",
        "Set a timer for 15–20 minutes and don't cheat.",
        "Asleep or calm and awake: leave well alone. Fussy but not screaming: give it longer.",
        "Screaming as if to wake the dead: go in and settle them the usual way. Some babies go from screaming straight to sleep, so use your judgement.",
        "It's an experiment, not a commitment. A few tries on different days costs nothing."
      ]
    },
    %{
      id: :double_take,
      name: "The double take",
      who: "Younger babies, under 4 months, but any age can try it",
      type: :experiment,
      nights: @default_nights,
      summary:
        "Settle them to sleep however works, put them down, then wake them slightly so they know they went to sleep in the crib.",
      steps: [
        "Remove the prop first: take out the pacifier, put down the baby from your arms or off the breast.",
        "Wake them a little: unzip the pyjamas, tickle a tummy, razz their toes, until they grumble at you.",
        "Let them drift back to sleep on their own in the crib.",
        "If nights haven't improved after a few nights, move to a different plan."
      ]
    }
  ]

  @doc "The corrected age in days from which a SWAP opens (2 months)."
  def min_age_days, do: @min_age_days

  @doc "The minutes taken off a motion-based soothe each night."
  def minutes_step, do: @minutes_step

  @doc "The pre-flight list as `{id, text}`; all of it is ticked by hand."
  def preflight, do: @preflight

  @doc "Ids of the pre-flight items."
  def preflight_ids, do: Enum.map(@preflight, &elem(&1, 0))

  @doc "The variants, in the order they're offered."
  def variants, do: @variants

  @doc "The variant with `id` (an atom or its string), or `nil`."
  def variant(id) when is_atom(id), do: Enum.find(@variants, &(&1.id == id))

  def variant(id) when is_binary(id),
    do: Enum.find(@variants, &(Atom.to_string(&1.id) == id))

  def variant(_), do: nil

  @doc "The ids of the variants as strings (for form values)."
  def variant_ids, do: Enum.map(@variants, &Atom.to_string(&1.id))

  @doc "How many nights `variant` runs."
  def nights(id) do
    case variant(id) do
      %{nights: nights} -> nights
      nil -> @default_nights
    end
  end

  @doc "The identifying facts of the plan family."
  def definition do
    %{id: :swap, name: "Sleep With Assistance Plan", min_age_days: @min_age_days}
  end

  @doc """
  What tonight asks for on night `night` of `variant_id`: `%{headline, target_minutes}`.
  `options` may carry `"start_minutes"`, how long the soothing took before the plan
  (30 when not given).

  The motion variants reduce `start_minutes` by five a night (never below zero).
  The chair has three stages. The others say the same thing every night.
  """
  def tonight(variant_id, night, options \\ %{}) when is_integer(night) and night >= 1 do
    variant = variant(variant_id) || raise ArgumentError, "unknown SWAP variant"
    start = start_minutes(options)

    case variant.id do
      id when id in [:jiggle, :pat] ->
        target = max(start - @minutes_step * (night - 1), 0)

        %{
          headline:
            if(target == 0,
              do: "No #{verb(id)} tonight: put them down awake and leave.",
              else: "#{String.capitalize(verb(id))} for at most #{target} minutes, then leave."
            ),
          target_minutes: target
        }

      :chair ->
        chair(night)

      :pull_out ->
        %{
          headline:
            "Let them suck until drowsy, take it out, lay them down. Put it back if they get upset, and take it out again before they're asleep.",
          target_minutes: nil
        }

      :anything_but ->
        %{
          headline:
            "Last feed 20 minutes before bed, then a rub, pats or shushing instead of sucking.",
          target_minutes: nil
        }

      :fuss_it_out ->
        %{
          headline:
            "Lay them down awake and give it 15–20 minutes before you go in. Leave a calm or grumbling baby alone.",
          target_minutes: 20
        }

      :double_take ->
        %{
          headline:
            "Settle them the usual way, take away the prop, lay them down, then wake them a little.",
          target_minutes: nil
        }
    end
  end

  defp chair(night) when night <= 2,
    do: %{
      headline:
        "Lying down in the crib with you touching them: patting, a hand on their tummy, a hum.",
      target_minutes: nil
    }

  defp chair(night) when night <= 4,
    do: %{
      headline:
        "Do less than last night: shorter, lighter, until you're only sitting there, quiet.",
      target_minutes: nil
    }

  defp chair(night) do
    feet = (night - 4) * @chair_step_feet

    %{
      headline:
        "Sit #{feet} feet from the crib, #{if feet >= 10, do: "by or outside the door", else: "closer to the door than last night"}, and be quiet. Out of the room once you're out the door.",
      target_minutes: nil
    }
  end

  defp verb(:jiggle), do: "jiggle the crib"
  defp verb(:pat), do: "pat them"

  defp start_minutes(options) do
    case options["start_minutes"] do
      n when is_integer(n) and n > 0 -> n
      _ -> 30
    end
  end

  @doc """
  What the nights so far say about a SWAP, from `Trygg.Reports.PlanNights`
  entries (oldest first): `{status, text}` with `status` `:early`, `:improving`,
  `:steady` or `:stalled` (a week or more and no better). The book's signs of
  progress are a shorter or easier bedtime and fewer wakings; its advice is to
  judge by the trend and to commit for five to seven nights.
  """
  def assess(nights, nights_planned) do
    times =
      for n <- nights, is_integer(n.bedtime_to_sleep_seconds), do: n.bedtime_to_sleep_seconds

    cond do
      length(times) < 3 ->
        {:early, "Too soon to say. Give it at least five nights."}

      length(times) >= nights_planned and List.last(times) >= hd(times) ->
        {:stalled,
         "A full run and bedtime is no easier. It may not be the right plan for them: take a few days, then try another variant or the sleep learning plan. Travel, illness or a growth spurt can also set it back; reset the clock and start again."}

      List.last(times) < hd(times) - 5 * 60 ->
        {:improving, "Bedtime is getting quicker than where you started. Keep going."}

      true ->
        {:steady,
         "About the same as at the start. Stay with it: five to seven nights, no slipping back."}
    end
  end

  @doc "Signs a SWAP is working, in the book's terms."
  def signs_of_progress do
    [
      "Bedtime is something everyone looks forward to.",
      "They're sleeping longer or with fewer interruptions.",
      "They sleep in the same place all night.",
      "You feel ready to do the same for naps."
    ]
  end

  @doc "Reasons a SWAP stalls, in the book's terms."
  def reasons_it_stalls do
    [
      "It isn't the right plan for them: babies differ.",
      "Not being consistent: any step back can undo it.",
      "You stalled: you changed a little, got nervous and stopped.",
      "Travel, illness, a regression or a growth spurt: reset the clock and start again."
    ]
  end

  @doc """
  What to check if bedtime is going well but nights are still broken (the book's
  list of the usual culprits).
  """
  def still_waking do
    [
      "You're still rocking, feeding or cuddling until they're nearly asleep. If you still see the old pattern, it's not awake enough.",
      "The last feed is the last step of the routine. Put a 20-minute gap between it and sleep.",
      "A pacifier at bedtime keeps the sucking habit going.",
      "You stay until they're asleep. That's a stepping stone, so leave before they fall asleep.",
      "A device on a timer turns off in the night."
    ]
  end
end
