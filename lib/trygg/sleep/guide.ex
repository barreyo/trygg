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

  # From *Precious Little Sleep*'s newborn chapter: why the nights are upside
  # down and what actually helps.
  @newborn_nights [
    "Newborns can't tell day from night yet. That's the body clock, and it settles by about two to four months with or without your help. You can't rush it, but light helps.",
    "Awake at night: keep it dim, quiet and boring, with white noise on. Try settling for about 20 minutes. If it's going nowhere, stop and try again 45–60 minutes later.",
    "Awake in the day: lots of light, especially outdoors in the morning, and lots going on.",
    "Don't wake a sleeping newborn to fix nights. It gives you a tired baby and doesn't fix the night.",
    "If bedtime attempts run past about 30 minutes, call it off and do something else for a while: a bath, a walk, the bouncer.",
    "Bedtime can be any time between 7 pm and midnight. Even a simple routine (diaper, pyjamas, swaddle, a song) starts to build a rhythm.",
    "A long first stretch after bedtime is the one to protect: go to bed when they do.",
    "Don't change a diaper at night unless it's dirty or leaking."
  ]

  @witching_hours [
    "Fussy and miserable somewhere between 5 and 11 pm is normal for newborns, and usually fades by about 8 weeks.",
    "Ask someone to walk the baby while you eat. Change the scenery every 10 minutes: bouncer, lap, bath, a walk outside.",
    "Cluster-feed. Now isn't the time to space feeds out.",
    "Taking turns is allowed, and so is a rough evening. You're not doing it wrong."
  ]

  @doc "Why newborn nights are upside down, and what helps."
  def newborn_nights, do: @newborn_nights

  @doc "Getting through the evening fuss (the \"witching hours\")."
  def witching_hours, do: @witching_hours

  @doc "The three habits the newborn routine rests on."
  def principles, do: @principles

  @doc "The newborn master schedule as `{time, activity}` rows."
  def master_schedule, do: @master_schedule

  @doc "What a phase (a `Trygg.Sleep.Phase` id) is about, as short paragraphs."
  def topics(phase_id), do: Map.get(@topics, phase_id, [])
end
