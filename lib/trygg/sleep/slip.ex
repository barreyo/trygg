defmodule Trygg.Sleep.Slip do
  @moduledoc """
  The "Sleep Learning Independence Plan" from *Precious Little Sleep* by Alexis
  Dubief: teaching a baby to fall asleep without help by putting them down awake
  in a safe crib and not rewarding the crying, either with no visits at all
  (`:full`, "full extinction") or with brief visits at growing intervals
  (`:graduated`, the book's "5-minute plan"). Both are effective; the book's own
  experience is that full works faster and with less crying, and says you can
  start graduated and move to full, never the other way round.

  The plan, in brief: bedtime first, naps looked after however you can; the same
  short, calm routine without the final soothe-to-sleep step; the old sleep
  prop (rocking, feeding, pacifier) gone for good; down in the crib awake and
  you leave; wakings in the night handled the way bedtime was.

  Everything here is data and small pure functions, in the shape of
  `Trygg.Sleep.Abcs` so the plan engine can run either. It needs a baby of at
  least 4 months (corrected) and a pediatrician's go-ahead. Not medical advice.
  """

  @min_age_days 122
  @nights 7
  @modes [:graduated, :full]

  # Seconds a visit lasts at most (the book says one or two minutes).
  @stay {60, 120}

  # {id, text}: the book's ten-point "is SLIP for us?" list, ours in words.
  @preflight [
    {"s-circadian",
     "Bedtime is steady (within 15–30 minutes) and is followed by their longest stretch of sleep, after their longest wake window of the day."},
    {"s-deprived",
     "They're getting well under the sleep they should, or waking so much that it's wearing everyone down."},
    {"s-root",
     "The problem is that they can't fall asleep alone, not hunger, early waking or something else."},
    {"s-tried",
     "We've made a real, committed attempt at a gradual approach first, or we can't carry on long enough for one."},
    {"s-medical", "No illness, fever or reflux flare-up right now."},
    {"s-safe", "The crib is empty and safe: no cords, nothing to climb, nothing soft."},
    {"s-unanimous", "We both agree, with no arguing about it halfway through."},
    {"s-schedule",
     "The next few weeks are steady: no trip, no big change, and the same place for day and night sleep."},
    {"s-monitor",
     "We have a night-vision monitor, so we can check they're safe without going in."},
    {"s-committed",
     "We're both committed: nothing like rocking, feeding or the pacifier at sleep again, even when it's hard."}
  ]

  @doc "The corrected age in days from which the plan opens (4 months)."
  def min_age_days, do: @min_age_days

  @doc "How many nights the plan runs before it's reviewed."
  def nights, do: @nights

  @doc "The check-in modes."
  def modes, do: @modes

  @doc "The identifying facts of the plan."
  def definition do
    %{
      id: :slip,
      name: "Sleep Learning Independence Plan",
      nights: @nights,
      min_age_days: @min_age_days,
      stay_seconds: @stay
    }
  end

  @doc "The pre-flight checklist as `{id, text}`; all of it is ticked by hand."
  def preflight, do: @preflight

  @doc "Ids of the pre-flight items."
  def preflight_ids, do: Enum.map(@preflight, &elem(&1, 0))

  @doc "The `{min, max}` seconds a visit lasts."
  def stay_seconds, do: @stay

  @doc """
  Seconds to wait before visit number `index` (0-based) of a waking on night
  `night` of the graduated plan: the first after five minutes times the night
  number, each later one five minutes longer than the one before. Night 1 is
  5, 10, 15 … minutes, night 2 is 10, 15, 20 …, night 5 is 25, 30, 35 ….
  """
  def checkin_interval(night, index)
      when is_integer(night) and night >= 1 and is_integer(index) and index >= 0,
      do: 300 * (night + index)

  @doc """
  The first `count` visit gaps for `night`, in seconds, as the book's "5-minute plan" table.
  """
  def schedule(night, count \\ 4),
    do: for(index <- 0..(count - 1), do: checkin_interval(night, index))

  @doc """
  What the book says to expect at bedtime on each night, as `%{label, lo, hi}`
  in minutes (`hi` nil past the third night): about 45–90 minutes of crying on
  night one, 20–45 on night two, up to 25 on night three. A rough guide: the
  trend over nights matters more than any one of them.
  """
  def expected(1), do: %{label: "45–90 minutes", lo: 45, hi: 90}
  def expected(2), do: %{label: "20–45 minutes", lo: 20, hi: 45}
  def expected(3), do: %{label: "0–25 minutes", lo: 0, hi: 25}
  def expected(n) when is_integer(n) and n > 3, do: %{label: "Under 25 minutes", lo: 0, hi: 25}

  @doc """
  What the nights so far say, from `Trygg.Reports.PlanNights` entries (oldest
  first): `{status, text}` with `status`

    * `:early` — fewer than two nights to compare.
    * `:improving` — time to fall asleep at bedtime is down from the first night.
    * `:burst` — a good night was followed by a worse one: likely an *extinction
      burst*, the crying picking up for a few nights once it stops working. Stay on the plan.
    * `:steady` — about the same as the first night.
    * `:stuck` — a full week and no better than the first night.
  """
  def assess(nights) do
    times =
      for n <- nights, is_integer(n.bedtime_to_sleep_seconds), do: n.bedtime_to_sleep_seconds

    case times do
      [] ->
        {:early, "Not enough nights yet. The first few vary a lot."}

      [_] ->
        {:early, "Not enough nights yet. The first few vary a lot."}

      [first | _] ->
        last = List.last(times)
        best_before = times |> Enum.drop(-1) |> Enum.min()

        cond do
          length(times) >= @nights and last >= first ->
            {:stuck,
             "A week in and bedtime is no easier than the first night. Talk to your pediatrician about whether this is the right time or the right method. The book says it can be a bad fit, and a gradual plan is the alternative."}

          last > best_before + 15 * 60 and best_before <= 25 * 60 ->
            {:burst,
             "Bedtime was easier a night ago and is harder again. That's very likely an extinction burst: crying that picks up when it stops working, and passes. Don't go back to the old way."}

          last < first - 5 * 60 ->
            {:improving,
             "Bedtime is quicker than on the first night. That's the pattern you're looking for."}

          true ->
            {:steady,
             "About the same as the first night so far. Stay consistent and look at the trend over a few more."}
        end
    end
  end

  @doc "The bullet points of the plan, in our words."
  def summary do
    [
      "Bedtime at the usual time, the same calm routine every night, but leave out the last step of soothing them to sleep.",
      "Whatever you're weaning them off (rocking, feeding, the pacifier) is gone from sleep for good, including at night.",
      "Put them down in the crib, awake, say your goodnight words, and leave.",
      "Graduated: go in briefly (a minute or two, no picking up, no feeding) at growing intervals. Full: don't go in until they're asleep.",
      "Make naps happen by any means for now (stroller, carrier); work on them after bedtime is sorted.",
      "Night wakings are handled the way bedtime was. A feed is fine if they've been eating at night, on a plan."
    ]
  end
end
