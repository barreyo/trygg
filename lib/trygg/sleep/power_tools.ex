defmodule Trygg.Sleep.PowerTools do
  @moduledoc """
  The four "sleep power tools" from *Precious Little Sleep*: the things that
  safely and substantially help a baby fall and stay asleep without you doing
  it for them. White noise, the swaddle, the pacifier and managing the sleep
  schedule. `plan/2` says, for a corrected age and the few facts only a parent
  knows, what to do with each one now: keep using it, think about stopping, or
  stop.

  Safety beats everything here. A baby who can roll, or is getting onto their
  side, is done with the swaddle that day, whatever the age.

  The wording is ours; the ages and numbers follow the book. Not medical advice.
  """

  # Ages in corrected days.
  @two_months 61
  @four_months 122
  @six_months 182
  @eight_months 243
  @twelve_months 365
  @two_years 730

  # Facts a parent ticks (stored in `children.sleep_checks`).
  @signals [
    {"pt-rolling", "They're rolling over, or getting onto their side."},
    {"pt-swaddle-escapes", "They keep getting out of the swaddle however it's done."},
    {"pt-paci-night", "They need the pacifier put back several times a night."}
  ]

  @doc "The facts a parent can tick, as `{id, text}`."
  def signals, do: @signals

  @doc "Ids of the facts a parent can tick."
  def signal_ids, do: Enum.map(@signals, &elem(&1, 0))

  @doc """
  What to do with each tool: a list of `%{id, name, state, headline, points}`
  (`points` are short lines). `state` is `:use`, `:consider` (it can go soon),
  `:stop` (it should go now) or `:optional`.

  `age_days` is the corrected age (`nil` when unknown); `ticks` is the child's
  `sleep_checks` map.
  """
  def plan(age_days, ticks \\ %{}) do
    ticks = ticks || %{}
    rolling? = Map.has_key?(ticks, "pt-rolling")
    escapes? = Map.has_key?(ticks, "pt-swaddle-escapes")
    paci_night? = Map.has_key?(ticks, "pt-paci-night")

    [
      white_noise(age_days),
      swaddle(age_days, rolling?, escapes?),
      pacifier(age_days, paci_night?),
      schedule(age_days)
    ]
  end

  defp white_noise(age) do
    {state, headline} =
      cond do
        is_nil(age) or age < @twelve_months ->
          {:use, "Keep it on whenever they sleep, all through the first year."}

        true ->
          {:optional,
           "Fine to keep. To stop, turn it down a little each day until it's off; bring it back if a noisy house starts to wake them."}
      end

    %{
      id: :white_noise,
      name: "White noise",
      state: state,
      headline: headline,
      points: [
        "About as loud as a shower heard from the next room, and never uncomfortably loud for you.",
        "It has to stay on all night, so nothing on a timer.",
        "Louder than the crying when you're using it to calm them. Quiet noise won't be heard.",
        "On while they sleep, off while they're awake, so it becomes a sleep cue."
      ]
    }
  end

  defp swaddle(_age, true, _escapes) do
    %{
      id: :swaddle,
      name: "Swaddle",
      state: :stop,
      headline: "Stop swaddling now. A swaddled baby who rolls onto their front is at real risk.",
      points: [
        "Pushing up onto their side counts: it's the step before rolling.",
        "Swaddling is only for babies who are on their back and can't flip.",
        "Moving on: one arm out for a few nights, a transition sleeper that frees the arms, or just stopping.",
        "Make sure every caregiver, including daycare, knows the rule."
      ]
    }
  end

  defp swaddle(age, false, escapes?) do
    {state, headline} =
      cond do
        is_nil(age) or age < @two_months ->
          {:use,
           "Most babies sleep better swaddled. Arms flush to the body, hips and legs free to move."}

        age < @four_months and escapes? ->
          {:consider,
           "They keep breaking out. A different blanket or style first, then stopping."}

        age < @four_months ->
          {:consider,
           "Fine while they're on their back and not close to rolling. Some families stop around two months, many by four."}

        true ->
          {:stop,
           "Past four months most babies are rolling or about to. Stop swaddling, one arm out first if you want a gentle step."}
      end

    %{
      id: :swaddle,
      name: "Swaddle",
      state: state,
      headline: headline,
      points: [
        "Snug on the arms, loose on the hips: two fingers fit at the chest.",
        "On their back, always, and never in a swaddle on their front.",
        "Not too warm: a baby under a swaddle may need only a diaper in summer.",
        "A grumble while being wrapped doesn't mean they dislike it."
      ]
    }
  end

  defp pacifier(age, paci_night?) do
    {state, headline} =
      cond do
        is_nil(age) or age < @four_months ->
          {:use,
           "Worth offering for sleep: falling asleep with one in is linked to lower SIDS risk, and it soothes. No need to put it back if it falls out."}

        age < @six_months ->
          {:consider,
           "The easiest time to drop it is around four to five months, before they remember it. Talk it over with the pediatrician if your baby is at higher SIDS risk (born early, smoke in the home)."}

        paci_night? ->
          {:stop,
           "If you're putting it back through the night, it's time. Cold turkey for a day or two usually does it."}

        age < @eight_months ->
          {:optional,
           "No hurry unless it starts costing sleep. Problems tend to start between four and eight months."}

        age < @twelve_months ->
          {:optional, "Fine for now. Aim to be done before their second birthday."}

        age < @two_years ->
          {:consider,
           "Aim to be done before two: it's linked to ear infections and, after two, to crooked teeth. Tell them first, then do it."}

        true ->
          {:stop, "Past two the teeth start to pay for it. Time to say goodbye to the pacifier."}
      end

    %{
      id: :pacifier,
      name: "Pacifier",
      state: state,
      headline: headline,
      points: [
        "Keep it for sleep after about six to eight weeks, so it stays special.",
        "Try a few kinds, when they're not starving, and at different times of day.",
        "The pull-out trick: gently tug it as if to take it away; they suck harder.",
        "Dropping it: reduce daytime use first, make sure other sleep cues are in place, then go cold turkey or use the pull-out method."
      ]
    }
  end

  defp schedule(age) do
    %{
      id: :schedule,
      name: "Sleep schedule",
      state: :use,
      headline:
        if(age && age < 91,
          do: "Not too long awake, and a simple rhythm. Newborns don't need a clock.",
          else:
            "Keep bedtime steady and the wake windows right for their age. It's the tool the others depend on."
        ),
      points: [
        "Overtired and undertired babies both fight sleep. The clock is more dependable than sleepy cues for many babies.",
        "Bedtime is the anchor: within 15–30 minutes of the same time, and earlyish.",
        "Don't let a short car or stroller nap late in the day eat the build-up to bedtime.",
        "It never really goes away. The older they get the more a late night or missed nap can be absorbed."
      ]
    }
  end

  @doc "Lovies: not in the crib before 12 months; a small breathable one after, shown to the pediatrician first."
  def lovey_note(age_days) when is_integer(age_days) and age_days >= @twelve_months,
    do:
      "A small, breathable lovey is probably fine now. Show it to the pediatrician before it goes in the crib."

  def lovey_note(_),
    do: "Nothing soft in the crib until after their first birthday, lovey included."
end
