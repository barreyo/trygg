defmodule Trygg.Sleep.Guide do
  @moduledoc """
  Reference content for the Sleep tab, distilled from the Taking Cara Babies
  guides: the newborn "master schedule" and what each phase of the journey is
  about. Plain data, so a screen can render it and a test can pin it.
  """

  @principles [
    "Offer feeds about every 2.5–3 hours.",
    "Practise breaking up feeding and sleeping when you can.",
    "Avoid an overtired baby."
  ]

  # {time, activity} from the "Daytime Routine" master schedule. A routine to
  # practise, not a timetable to follow.
  @master_schedule [
    {"7:00 am", "Feeding"},
    {"7:30 – 8:00 am", "Awake time"},
    {"8:00 – 10:00 am", "Sleeping"},
    {"10:00 am", "Feeding"},
    {"10:30 – 11:00 am", "Awake time"},
    {"11:00 am – 1:00 pm", "Sleeping"},
    {"1:00 pm", "Feeding"},
    {"1:30 – 2:00 pm", "Awake time"},
    {"2:00 – 4:00 pm", "Sleeping"},
    {"4:00 pm", "Feeding"},
    {"4:30 – 5:00 pm", "Awake time"},
    {"5:00 – 7:00 pm", "Sleeping"},
    {"7:00 pm", "Feeding"},
    {"7:30 – 8:00 pm", "Awake time"},
    {"8:00 – 10:00 pm", "Sleeping"},
    {"10:00 pm", "Dream feed (optional)"}
  ]

  @topics %{
    newborn: [
      "Watch for sleepy cues and start a nap as soon as they show: it's easier to settle a baby who is tired than one who has tipped into overtired.",
      "Feed about every 2.5–3 hours, and practise feed → awake time → sleep when it's easy. Feeding to sleep is fine too.",
      "Calm crying with C.R.I.E.S.: contain, roll onto the side, introduce movement, external sound, suck.",
      "From about 8 weeks they can recognise repetition: start a short, predictable wind-down before sleep."
    ],
    foundations: [
      "Wake windows grow to 75–120 minutes, shortest first thing in the morning and longest before bed.",
      "Aim for 3–4 naps and about 3.5–4.5 hours of daytime sleep, never more than 5, and wake a nap that passes 2 hours.",
      "Move bedtime toward 7–8 pm, with the last nap ending 100–120 minutes before it.",
      "A 25–30 minute bedtime routine with 4–5 steps, a dark room and a constant sound machine.",
      "Practise falling asleep with less help (S.I.T. B.A.C.K. for night wakings), and aim for one night feed by the end of month four.",
      "Stop swaddling once they roll, and wean off sleep products gradually."
    ],
    beyond: [
      "Everything from Foundations still applies, and you can keep going on that path as long as you like.",
      "If nights are still hard, or you want to do more, \"The ABCs of Sleep\" is the 14-night active sleep-training plan the guides point to from 5 months.",
      "Sleep training is optional. It's fine to keep going as you are."
    ]
  }

  @doc "The three habits the newborn routine rests on."
  def principles, do: @principles

  @doc "The newborn master schedule as `{time, activity}` rows."
  def master_schedule, do: @master_schedule

  @doc "What a phase (a `Trygg.Sleep.Phase` id) is about, as short paragraphs."
  def topics(phase_id), do: Map.get(@topics, phase_id, [])
end
