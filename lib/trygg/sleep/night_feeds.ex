defmodule Trygg.Sleep.NightFeeds do
  @moduledoc """
  The night-feed plan from the 3–4 month guide: find the child's "best
  baseline" (the longest they recently and repeatedly go without a night feed),
  hold to it, and shave the night feeds down a little every other night, aiming
  for at most one by the end of the fourth month. The dream feed (about
  9:30–11 pm) isn't part of the reduction.

  Nothing here says a feed *should* be dropped. It is gated three ways before
  it offers a plan at all: the child is at least 13 weeks (corrected), their
  weight gain looks on track in Vitals, and a caregiver has recorded that the
  pediatrician is fine with night weaning. Without all three it only explains
  what's missing.

  Pure: takes the child, their `Trygg.Sleep.Phase`, growth
  (`Trygg.Growth.Velocity.summarize/2`), nights (`Trygg.Reports.Nights`) and
  the time of the last feed.
  """

  alias Trygg.Families.Child

  @min_gap_seconds 3 * 3600
  # Reduce a bottle by about half an ounce, or a nursing session by 2 minutes.
  @bottle_step_ml 15
  @nursing_step_minutes 2
  # A weigh-in older than this isn't evidence that weight gain is on track.
  @stale_weight_days 21
  # Feeds in this local-time window are the dream feed, not night feeds to wean.
  @dream_feed {21 * 60 + 30, 23 * 60}
  @goal_feeds 1
  @recent_nights 5

  # How many night feeds is usual, by corrected age in days (*Precious Little
  # Sleep*): `{from_days, label, low, average, high}`. Breastfed babies tend to
  # sit in the average or high columns, bottle-fed ones low or average.
  @typical [
    {0, "0–3 months", "1–2", "3–4", "6"},
    {91, "3–6 months", "0", "2–3", "4"},
    {182, "6–9 months", "0", "0–2", "2–3"},
    {274, "9–12 months", "0", "0–1", "2"}
  ]

  # Rules of thumb for deciding which night wakings get a feed once a baby is
  # falling asleep on their own (the book's chapter on handling night waking).
  @rules [
    "Before about midnight, hold off if you can: an early feed can bring back the habit of eating to sleep.",
    "Keep the gap between feeds like the day's: three to four hours.",
    "Either go to them within 5–10 minutes or wait until they're back asleep. Letting them complain for 40 minutes and then feeding teaches them to complain.",
    "A feed that wasn't wanted for an hour is not hungry crying. A short grumble that stops is not hunger either.",
    "For the first couple of nights be flexible; from the third, stick to the plan.",
    "Once a feed has gone, it stays gone, apart from illness or a bad week. Don't let weaning turn into whack-a-mole.",
    "A feed around 4:30–5:30 am (the \"snooze button\") is often worth keeping if the choice is that or a 5 am start."
  ]

  # When a dream feed (feeding a baby who's mostly asleep, at a time that suits
  # you) earns its place.
  @dream_feed_uses [
    "To move a feed to a better time: a baby who wakes an hour after you go to bed can be fed as you go to bed.",
    "To help a baby who is very keen on the breast cut back: half asleep, they're easier to pop off early.",
    "To feed them without rewarding waking: they eat without having to wake themselves up for it."
  ]

  @doc "How many night feeds are usual at `age_days` as `%{label, low, average, high}`, or `nil`."
  def typical(age_days) when is_integer(age_days) and age_days >= 0 do
    case @typical |> Enum.filter(&(elem(&1, 0) <= age_days)) |> List.last() do
      {_from, label, low, average, high} ->
        %{label: label, low: low, average: average, high: high}

      nil ->
        nil
    end
  end

  def typical(_), do: nil

  @doc "Rules of thumb for which night wakings get a feed once they fall asleep on their own."
  def rules, do: @rules

  @doc "When a dream feed earns its place."
  def dream_feed_uses, do: @dream_feed_uses

  @doc "The dream feed window as `{from, to}` in minutes since local midnight."
  def dream_feed_window, do: @dream_feed

  @doc "The step a bottle is reduced by, in ml."
  def bottle_step_ml, do: @bottle_step_ml

  @doc "The step a nursing session is reduced by, in minutes."
  def nursing_step_minutes, do: @nursing_step_minutes

  @doc """
  Whether night weaning is open to this child, and why not if it isn't:
  `%{age, weight, clearance, ready?}`.

    * `age` — `{:ok, nil}` or `{:locked, unlock_date}`.
    * `weight` — `:ok`, `:needs_check` (no recent weigh-in) or `:flag` (gaining
      slower than the guide or dropping across percentile bands); with a
      `weight_detail` sentence.
    * `clearance` — the date the pediatrician's go-ahead was recorded, or `nil`.
  """
  def gates(%Child{} = child, phase, growth, %Date{} = today) do
    age = age_gate(phase)
    {weight, detail} = weight_gate(growth, today)
    clearance = child.night_weaning_cleared_on

    %{
      age: age,
      weight: weight,
      weight_detail: detail,
      clearance: clearance,
      ready?: match?({:ok, _}, age) and weight == :ok and not is_nil(clearance)
    }
  end

  defp age_gate(%{age_days: age}) when age >= 91, do: {:ok, nil}
  defp age_gate(%{next: %{id: :foundations, on: on}}), do: {:locked, on}
  defp age_gate(_phase), do: {:locked, nil}

  defp weight_gate(%{available?: true, latest: %{date: date}, velocity: velocity}, today) do
    cond do
      Date.diff(today, date) > @stale_weight_days ->
        {:needs_check, "The last weigh-in was #{Date.diff(today, date)} days ago."}

      velocity && velocity.percentile_drop? ->
        {:flag, "Weight has dropped across percentile bands since the last check."}

      velocity && velocity.guide_status == :below ->
        {:flag, "Weight gain is below the usual range for this age."}

      true ->
        {:ok, "Weight gain looks on track."}
    end
  end

  defp weight_gate(_growth, _today),
    do: {:needs_check, "Log a couple of weigh-ins in Vitals so gain can be checked."}

  @doc """
  The plan for tonight. `nights` is a `Trygg.Reports.Nights.summarize/3` map,
  `last_feed_at` the time of the last feed (or `nil`) and `now` the current time.

  Returns `%{baseline_seconds, average_feeds, goal_met?, earliest, last_night,
  action, tonight}`:

    * `earliest` — `%{at, seconds_left, state}`: the earliest to offer a feed,
      the last feed plus the best baseline and never less than 3 hours; `state`
      is `:wait` or `:open`. `nil` without a last feed.
    * `action` — `:reduce` (take a step down tonight), `:hold` (a cut was made
      last night, so keep it tonight) or `:none` (no night feeds to reduce).
    * `tonight` — the last night's feeds with their suggested amounts.
  """
  def plan(%Child{} = child, nights, last_feed_at, %DateTime{} = now) do
    recent = Enum.take(nights.nights, @recent_nights)
    baseline = nights.best_baseline_seconds

    {action, tonight} = reduction(child, recent)

    %{
      baseline_seconds: baseline,
      average_feeds: average(Enum.map(recent, & &1.feeds)),
      goal_met?:
        recent != [] and average(Enum.map(recent, &length(weanable(child, &1)))) <= @goal_feeds,
      earliest: earliest(last_feed_at, baseline, now),
      last_night: List.first(recent),
      action: action,
      tonight: tonight
    }
  end

  defp earliest(nil, _baseline, _now), do: nil

  defp earliest(%DateTime{} = last, baseline, now) do
    gap = max(baseline || 0, @min_gap_seconds)
    at = DateTime.add(last, gap, :second)
    left = DateTime.diff(at, now, :second)
    %{at: at, seconds_left: max(left, 0), state: if(left > 0, do: :wait, else: :open)}
  end

  # Every other night: hold after a reduction, reduce when the last two nights
  # matched (so the last cut was a night ago, or there hasn't been one).
  defp reduction(child, recent) do
    with_feeds = Enum.filter(recent, &(weanable(child, &1) != []))

    case with_feeds do
      [] ->
        {:none, []}

      [last] ->
        {:reduce, reduce_all(weanable(child, last))}

      [last, before | _] ->
        if reduced?(weanable(child, last), weanable(child, before)),
          do: {:hold, hold_all(weanable(child, last))},
          else: {:reduce, reduce_all(weanable(child, last))}
    end
  end

  # Night feeds that count toward weaning: everything but the dream feed.
  defp weanable(child, night) do
    Enum.reject(night.feed_events, fn event ->
      {lo, hi} = @dream_feed
      minutes = local_minutes(child, event.at)
      minutes >= lo and minutes <= hi
    end)
  end

  defp reduced?(last, before) do
    amount(last) < amount(before) * 0.93
  end

  defp amount(events) do
    Enum.sum(for e <- events, do: e.ml || (e.minutes || 0) * 10.0)
  end

  defp reduce_all(events), do: Enum.map(events, &suggest(&1, true))
  defp hold_all(events), do: Enum.map(events, &suggest(&1, false))

  defp suggest(%{kind: :feeding, ml: ml} = event, reduce?) when is_number(ml) do
    Map.put(event, :suggested_ml, if(reduce?, do: max(ml - @bottle_step_ml, 0), else: ml))
  end

  defp suggest(%{kind: :breastfeeding, minutes: minutes} = event, reduce?)
       when is_integer(minutes) do
    Map.put(
      event,
      :suggested_minutes,
      if(reduce?, do: max(minutes - @nursing_step_minutes, 0), else: minutes)
    )
  end

  defp suggest(event, _reduce?), do: event

  defp average([]), do: 0.0
  defp average(list), do: Enum.sum(list) / length(list)

  defp local_minutes(child, at) do
    local = DateTime.shift_zone!(at, child.timezone)
    local.hour * 60 + local.minute
  end
end
