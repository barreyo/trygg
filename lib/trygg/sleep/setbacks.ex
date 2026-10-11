defmodule Trygg.Sleep.Setbacks do
  @moduledoc """
  The bumps in the road, from *Precious Little Sleep*'s chapter on setbacks and
  the bedtime chapter: sleep regressions, new skills, separation anxiety,
  travel, daylight saving, sleep debt, naps that won't happen, too long in bed,
  night gaps and very early mornings.

  Two kinds of thing live here. `playbooks/0` is the advice as short cards (our
  wording, the book's numbers). The planners (`shift_plan/1`, `dst_plan/2`,
  `travel_plan/1`, `next_dst_change/2`) turn the book's rules of thumb into a
  day-by-day list so there's no sums to do at 3 a.m.

  Times are minutes after local midnight. A bedtime past midnight is given as
  more than 1440 (01:00 is 1500), so a late night shifts earlier without a
  wrap-around.
  """

  alias Trygg.Families.Child

  @shift_step 15

  # Corrected ages (months) around which regressions are most often reported.
  @regression_months [4, 6, 9, 12, 18, 24]
  @regression_slack_days 21

  @doc "The minutes a bedtime or wake time moves each day in a gradual shift."
  def shift_step, do: @shift_step

  ## Playbooks ----------------------------------------------------------------

  # {id, title, summary, points}
  @playbooks [
    %{
      id: :regression,
      title: "A sleep regression",
      summary:
        "A week or two of bad sleep, fussing and clinging, usually while they're growing or learning something. Common around 4, 6 and 8–10 months, and again near 12 and 18. About half of babies get each one.",
      points: [
        "Don't panic. It's a bad week or two, and it ends.",
        "Do what works for now: a stroller nap, an extra feed. You can unpick it later.",
        "Then get back on the path. If a month later you're still rocking or feeding to sleep, the survival tactic has become the new normal.",
        "Eating more during one is normal. Let them."
      ]
    },
    %{
      id: :new_skills,
      title: "New skills",
      summary:
        "Rolling, sitting, standing, crawling and walking all get practised at bedtime and 2 a.m. for a few days, then they show off and sleep again.",
      points: [
        "Practise the skill a lot during the day so night doesn't have to be the practice.",
        "Standing and can't sit down? Practise sitting from standing by the sofa all day, then in the crib remind them once how to bend the knees, and go. Don't lay them down for them."
      ]
    },
    %{
      id: :separation,
      title: "Separation anxiety",
      summary:
        "From about six months, peaking around eight or nine. Often confused with not knowing how to fall asleep alone: a child who has learned to settle usually copes fine.",
      points: [
        "A bedtime routine long enough to move them from play to sleep, with the same words each night.",
        "Fill their cup in the day: holding, wearing, your full attention.",
        "Practise short separations: \"I'm putting the washing in, back in two minutes.\"",
        "Stay loving and steady at bedtime. Don't let it grow into extra cuddles, then five more."
      ]
    },
    %{
      id: :sleep_debt,
      title: "Sleep debt",
      summary:
        "Illness, travel and a skipped nap leave them tired, and tired babies sleep worse, which makes more debt.",
      points: [
        "Make sleep happen by any-ish means: a stroller or carrier nap is better than none and won't undo independent sleep.",
        "Bedtime 30 minutes earlier for a few days, up to a week, to catch up.",
        "Then back to the usual bedtime."
      ]
    },
    %{
      id: :no_nap_baby,
      title: "A nap that won't happen (baby)",
      summary: "Even great nappers have days like this.",
      points: [
        "The 20-minute rule: give it 20 minutes at the start of the nap, or 20 minutes of trying again after a short one, then let it go.",
        "They'll be tired and fussy. Try again at the next nap, and consider bedtime 30 minutes earlier.",
        "An occasional bad nap day is the way of baby."
      ]
    },
    %{
      id: :no_nap_toddler,
      title: "A toddler who says no to naps",
      summary: "Under three they almost always still need one, even when they don't want one.",
      points: [
        "The one-hour rule: the same place, the same time, a calm routine, dull and dark and safe, for an hour.",
        "What they do in there is up to them. Counting toes loses its appeal in a few days.",
        "Same tone as talking about the weather. No power struggle."
      ]
    },
    %{
      id: :too_long_in_bed,
      title: "Too long in bed",
      summary:
        "Rare. If they struggle to fall asleep, start the day too early or lie awake at night even though sleep habits are good, they may be getting more sleep than they need.",
      points: [
        "Naps far longer than the age guide? Cap them.",
        "Last wake window before bed too short? A late nap or catnap can be the reason.",
        "Around 6–12 months many babies settle at about 11 hours a night. That's growing up, not a problem."
      ]
    },
    %{
      id: :night_gap,
      title: "A night gap",
      summary:
        "They go down fine, then are wide awake for an hour or two in the middle of the night and nothing works. Often too much sleep in total.",
      points: [
        "Rule out the usual causes first: how they fall asleep, what you do when they wake.",
        "Then cut daily sleep by the length of the gap. If naps are big, trim naps; if night is 13 hours, trim the night.",
        "Give it a week."
      ]
    },
    %{
      id: :early_morning,
      title: "Waking at an uncivilized hour",
      summary:
        "Six to six-thirty is a reasonable target; some babies can't make it past five or five-thirty. Aim for about 11 hours of unbroken night.",
      points: [
        "Bedtime too late makes an overtired early riser. Move it 15 minutes earlier a day for 3–5 days.",
        "Bedtime too early locks them in: 6 pm to 5 am is 11 hours. Try later, 15 minutes a day, with bright light in the late afternoon.",
        "Rule things out: light, noise, a leaky diaper, hunger (a 5 a.m. snooze-button feed is the least bad option), and needing a little soothing to get through the light sleep before dawn.",
        "Advanced: wake them a little 45 minutes before they usually wake and let them go back down.",
        "Toddlers 2 and up: a \"reverse alarm clock\" light, set 15 minutes later than they wake now, adding 15 minutes every 3–4 days."
      ]
    },
    %{
      id: :teething,
      title: "Teething",
      summary:
        "Studies say it matters less than parents feel it does, but it can make them irritable and restless for a few days.",
      points: [
        "Distract: go out, give them something cold (fridge, not freezer) to chew on.",
        "No benzocaine gels and no amber beads.",
        "At night, nothing works unless they hold it. If they seem to be suffering, ask the pediatrician about pain relief."
      ]
    }
  ]

  @doc "The playbook cards as `%{id, title, summary, points}`."
  def playbooks, do: @playbooks

  # Things that can sit behind poor sleep and are worth a conversation with the
  # pediatrician. Most poor sleep is simply babies; these are the exceptions.
  @medical [
    %{
      id: :reflux,
      title: "Reflux",
      points: [
        "Spit-up is normal. The question is whether it hurts: much more than three hours of crying a day, crying through or after feeds, arching, frequent hiccups or coughing, refusing the feed after a little, or crying more on their back.",
        "Sleeping badly in the day, especially, with a baby who seems to be in pain.",
        "Worth asking about: keeping them upright for 20–30 minutes after feeds, a dairy trial (milk protein, not just lactose), thicker feeds, more soothing, a strict schedule. Most cases are over by a year."
      ]
    },
    %{
      id: :allergy,
      title: "Food allergy or intolerance",
      points: [
        "Eczema, mucus or blood in the stool, severe gas, rashes, congestion, vomiting. Most babies with these symptoms don't have an allergy.",
        "Cow's milk protein is the commonest in infants. Keep a food diary and take it to the pediatrician before cutting anything out."
      ]
    },
    %{
      id: :apnea,
      title: "Snoring and sleep apnea",
      points: [
        "Regular snoring, mouth breathing in sleep, stretching the neck back to breathe, pauses in breathing, restless sleep.",
        "A stuffy nose snores too. If it's not a cold, ask."
      ]
    },
    %{
      id: :restless_legs,
      title: "Restless legs",
      points: [
        "Toddlers and older: an urge to move the legs at night that moving relieves. It runs in families. If sleep is badly broken and a parent has it, ask."
      ]
    },
    %{
      id: :prematurity,
      title: "Born early",
      points: [
        "Higher SIDS risk: always on their back, in a safe space. Never on their side or tummy because the NICU did it.",
        "Use their corrected age for everything here. They catch up."
      ]
    }
  ]

  @doc "Things that can sit behind poor sleep and are worth asking the pediatrician about."
  def medical, do: @medical

  @doc "The playbook with `id`, or `nil`."
  def playbook(id), do: Enum.find(@playbooks, &(&1.id == id))

  @doc """
  `{months, days_to_go}` when `age_days` (corrected) is within three weeks
  either side of an age where regressions are often reported, else `nil`.
  `days_to_go` is negative once the age has passed.
  """
  def regression_window(age_days) when is_integer(age_days) do
    @regression_months
    |> Enum.map(fn months -> {months, round(months * 30.4375) - age_days} end)
    |> Enum.find(fn {_months, to_go} -> abs(to_go) <= @regression_slack_days end)
  end

  def regression_window(_), do: nil

  ## Bedtime and wake time shifts ----------------------------------------------

  @doc """
  A day-by-day plan to move bedtime (and optionally the wake time) 15 minutes a
  day from where it is to where you want it:

      shift_plan(%{from_bed: 22 * 60, to_bed: 19 * 60 + 30, from_wake: 11 * 60, to_wake: 6 * 60 + 30})

  The book's rule: a late bedtime with enough total sleep moves earlier by waking them
  15 minutes earlier each morning and shifting everything with it; a bedtime that
  is merely late moves earlier on its own, keeping the same wake time. With
  `:wake` shifting omitted (`to_wake` nil) only the bedtime moves.

  Returns `[%{day, bed, wake}]` (`wake` may be `nil`), the last row being the
  target, capped at 60 days.
  """
  def shift_plan(%{from_bed: from_bed, to_bed: to_bed} = params) do
    from_wake = params[:from_wake]
    to_wake = params[:to_wake]
    from_bed = night(from_bed)
    to_bed = night(to_bed)

    steps = max(steps_between(from_bed, to_bed), steps_between(from_wake, to_wake))
    steps = min(steps, 60)

    for day <- 1..steps//1 do
      %{
        day: day,
        bed: move(from_bed, to_bed, day),
        wake: from_wake && to_wake && move(from_wake, to_wake, day)
      }
    end
    |> Enum.map(fn row ->
      %{row | bed: rem(row.bed, 1440), wake: row.wake && rem(row.wake, 1440)}
    end)
  end

  # A time of day before 6 am is treated as the small hours of the night before.
  defp night(minutes) when minutes < 6 * 60, do: minutes + 1440
  defp night(minutes), do: minutes

  defp steps_between(nil, _), do: 0
  defp steps_between(_, nil), do: 0
  defp steps_between(from, to), do: ceil(abs(to - from) / @shift_step)

  defp move(from, to, day) do
    delta = day * @shift_step
    if to < from, do: max(from - delta, to), else: min(from + delta, to)
  end

  ## Daylight saving ------------------------------------------------------------

  @doc """
  The next change of clock in the child's time zone within 70 days of `today`:
  `%{date, direction: :forward | :back}` (the date the clocks change, i.e. the
  morning they differ), or `nil`.
  """
  def next_dst_change(%Child{timezone: zone}, %Date{} = today) do
    zone
    |> offsets(today)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn [{_d1, o1}, {d2, o2}] ->
      cond do
        o2 > o1 -> %{date: d2, direction: :forward}
        o2 < o1 -> %{date: d2, direction: :back}
        true -> nil
      end
    end)
  end

  defp offsets(zone, today) do
    for n <- 0..70 do
      date = Date.add(today, n)

      case DateTime.new(date, ~T[12:00:00], zone) do
        {:ok, dt} -> {date, dt.utc_offset + dt.std_offset}
        _ -> {date, 0}
      end
    end
  end

  @doc """
  What to do about a clock change. `direction` is `:forward` (spring: an hour
  earlier on the clock) or `:back` (autumn), `date` the day the clocks change,
  and `usual` `%{bed: minutes, wake: minutes}` what their day is now.

  Spring: shift bedtime, wake and naps 15 minutes earlier on each of the four
  days before, so that on the day itself they're at their usual times on the new
  clock. Rows are `%{date, bed, wake, new_clock?}`; the last row's wake time is
  on the new clock.

  Autumn: nothing to move, but the body clock needs help: bright light for an
  hour in the evening and a dark, dull morning until the new wake time.
  `%{rows: [], tips: [...]}`.
  """
  def dst_plan(:forward, date, %{bed: bed, wake: wake}) do
    rows =
      for k <- 1..4 do
        %{
          date: Date.add(date, k - 5),
          bed: bed - @shift_step * k,
          wake: if(k < 4, do: wake - @shift_step * k, else: wake),
          new_clock?: k == 4
        }
      end

    %{
      rows: rows,
      tips: [
        "Move naps with bedtime: 15 minutes earlier each day.",
        "Dim the lights for the hour before bed, and no screens. Early bedtimes are hard because the body is wired to be awake just before sleep.",
        "Bright light early in the morning moves the body clock earlier.",
        "A baby who wakes at 4–5 am can use the change: leave the schedule alone, and the same times fall an hour later on the new clock."
      ]
    }
  end

  def dst_plan(:back, _date, _usual) do
    %{
      rows: [],
      tips: [
        "Keep their usual bedtime and wake time on the new clock. They'll wake an hour early at first.",
        "Evenings: about an hour of bright light (outside, a bright room or a light box) until they sleep to the new wake time.",
        "Mornings: lights low, activity low, and no feeding until the new wake time.",
        "Let the day follow wake windows rather than the clock for a few days, so naps can slide.",
        "A baby who goes to bed far too late can use the change: keep the bedtime the same and it falls an hour earlier on the new clock."
      ]
    }
  end

  ## Travel ----------------------------------------------------------------------

  @doc """
  A plan for crossing `hours` time zones (`direction` `:east` or `:west`) for
  `days` days. One zone for under a week: keep home time. Otherwise count on
  about a day per hour to adjust, and use bright light at the right time on
  home-clock: late afternoon going west (to move bedtime later), early morning
  going east (to move it earlier).

  Returns `%{keep_home_time?, adjust_days, light, tips}` where `light` is
  `{from, to}` in minutes after midnight on the *home* clock, or `nil`.
  """
  def travel_plan(%{hours: hours, direction: direction, days: days}) do
    keep? = hours <= 1 and days < 7
    light = if keep?, do: nil, else: light_window(direction)

    %{
      keep_home_time?: keep?,
      adjust_days: if(keep?, do: 0, else: hours),
      light: light,
      tips: travel_tips(keep?, direction)
    }
  end

  defp light_window(:west), do: {17 * 60, 19 * 60}
  defp light_window(:east), do: {5 * 60 + 30, 7 * 60 + 30}

  defp travel_tips(keep?, direction) do
    base = [
      "Keep to their usual schedule as strictly as you can, in whatever time zone you're in.",
      "Bring everything familiar: sleep sack, sound machine, blackout.",
      "Practise in the travel bed at home a few times first.",
      "Don't let them oversleep in the day.",
      "If they usually fall asleep alone, keep it that way. Be more generous at bedtime if you must, but don't turn an independent sleeper into a dependent one.",
      "A stroller or carrier nap beats a skipped nap.",
      "Expect shorter naps and early mornings, and a few rough days after you get home."
    ]

    cond do
      keep? ->
        ["One hour for a short trip: stay on home time. It saves adjusting twice." | base]

      direction == :west ->
        [
          "Going west their bedtime has to move later: get them into bright light in the late afternoon or early evening, home time."
          | base
        ]

      true ->
        [
          "Going east their bedtime has to move earlier: get them into bright light in the early morning, home time."
          | base
        ]
    end
  end
end
