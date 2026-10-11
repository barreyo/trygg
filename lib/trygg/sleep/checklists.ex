defmodule Trygg.Sleep.Checklists do
  @moduledoc """
  The two checklists from the 3–4 month guide: a **success** checklist of the
  habits and milestones that mean sleep is on its way, and a **troubleshooting**
  list to run through when nights are hard.

  Some success items tick themselves from the log (night feeds, wakings, bedtime
  consistency, how they fall asleep, cues noted); the rest are ticked by hand and
  remembered in `children.sleep_checks`. Troubleshooting items are all
  questions to answer yourself; a couple carry a hint from the data.

  Pure: `evaluate/1` takes `%{child, nights, falling_asleep, habits}`.
  """

  alias Trygg.Families.Child

  @bedtime_window {19 * 60, 20 * 60}
  @recent 5

  # {id, text, auto?}: `auto?` ids are decided by `auto/2`.
  @success [
    {"day-calories", "Most of their calories come during the day (no reverse cycling).", true},
    {"environment", "Their room is dark, cool and has a constant sound machine.", false},
    {"bedtime-consistent", "Bedtime is consistent, between 7 and 8 pm.", true},
    {"routine", "A bedtime and a nap routine are in place.", false},
    {"routine-cue", "They recognise the routine as a cue for sleep.", false},
    {"falling-asleep-alone", "They're falling asleep with less help than before.", true},
    {"seen-self-sleep", "I've seen them put themselves to sleep.", true},
    {"crib", "They sleep in the crib, even if only for one nap a day.", false},
    {"slow-to-step-in", "I wait before stepping in when I hear them at night.", false},
    {"slow-binky", "I'm slower to replace the pacifier at night.", false},
    {"rough-night-plan", "I have a plan for when a night gets overwhelming.", false},
    {"not-every-waking-fed", "Not every night waking ends in a feed.", true},
    {"self-settle-night", "I've heard them settle themselves back to sleep at night.", false},
    {"fewer-wakings", "They're waking less at night than they were.", true},
    {"fewer-night-feeds", "They're having fewer feeds at night.", true},
    {"nap-control", "I know what I can steer for naps and what they control.", false},
    {"cues-and-windows", "I'm noting sleepy cues and watching wake windows.", true},
    {"daytime-routine", "We have a typical daytime routine (not a strict schedule).", false},
    {"one-nap-45", "They usually take at least one nap a day over 45 minutes.", false},
    {"day-sleep-ok", "They're not sleeping too much in the day.", false},
    {"swaddle", "We've started or finished moving out of the swaddle.", false},
    {"props", "We've moved away from some or all sleep props.", false},
    {"tummy", "They're content sleeping on their tummy once they roll.", false},
    {"hard-night-plan", "I know what to do if nights get difficult.", false}
  ]

  @troubleshooting [
    {"t-feeds", "Are they eating every 2–4 hours during the day?"},
    {"t-full-feeds", "Are daytime feeds full, without being distracted?"},
    {"t-calories", "Have you added enough calories in the day as night feeds come down?"},
    {"t-fall-asleep", "Are they putting themselves to sleep at night?"},
    {"t-day-sleep", "Are they getting about 3–4.5 hours of daytime sleep?"},
    {"t-windows", "Are wake windows long enough, and stimulating?"},
    {"t-last-window", "Is the last wake window before bed 1.5–2.5 hours?"},
    {"t-partner", "Has your partner tried to settle them and tried S.I.T. B.A.C.K.?"},
    {"t-dream-feed", "Is a dream feed helping, or has it started to cause more trouble?"},
    {"t-environment",
     "Is the room dark, with a constant sound machine, and some distance from you?"},
    {"t-comfort", "Are they comfortable: clothing, temperature, teething, reflux?"},
    {"t-props", "Have sleep props been changed gradually rather than all at once?"},
    {"t-expectations", "Are your expectations for naps right for their age?"}
  ]

  @doc "All success item ids."
  def success_ids, do: Enum.map(@success, &elem(&1, 0))

  @doc "All troubleshooting item ids."
  def troubleshooting_ids, do: Enum.map(@troubleshooting, &elem(&1, 0))

  @doc """
  `%{success, troubleshooting, success_done, success_total}`. Each item is
  `%{id, text, checked?, auto?, detail}` (`detail` is a short reason for an
  automatic item, or a hint).
  """
  def evaluate(%{child: %Child{} = child} = ctx) do
    ticks = child.sleep_checks || %{}

    success =
      for {id, text, auto?} <- @success do
        {checked?, detail} = if auto?, do: auto(id, ctx), else: {Map.has_key?(ticks, id), nil}
        %{id: id, text: text, checked?: checked?, auto?: auto?, detail: detail}
      end

    troubleshooting =
      for {id, text} <- @troubleshooting do
        %{
          id: id,
          text: text,
          checked?: Map.has_key?(ticks, id),
          auto?: false,
          detail: hint(id, ctx)
        }
      end

    %{
      success: success,
      troubleshooting: troubleshooting,
      success_done: Enum.count(success, & &1.checked?),
      success_total: length(success)
    }
  end

  ## Automatic success items ---------------------------------------------------

  defp auto("day-calories", %{nights: %{nights: nights}}) do
    recent = Enum.take(nights, @recent)

    if length(recent) >= 3 do
      avg = average(Enum.map(recent, & &1.feeds))
      {avg <= 1.0, "#{format(avg)} night feeds a night over the last #{length(recent)} nights"}
    else
      {false, "needs 3 nights"}
    end
  end

  defp auto("bedtime-consistent", %{child: child, nights: %{nights: nights}}) do
    recent = Enum.take(nights, @recent)
    {lo, hi} = @bedtime_window

    if length(recent) >= 4 do
      inside = Enum.count(recent, &(local_minutes(child, &1.bedtime) in lo..hi))
      {inside >= 4, "#{inside} of the last #{length(recent)} bedtimes were 7–8 pm"}
    else
      {false, "needs 4 nights"}
    end
  end

  defp auto("falling-asleep-alone", %{falling_asleep: %{tracked: tracked} = fa})
       when tracked >= 3 do
    this = fa.this_week.mean_level

    cond do
      is_number(fa.trend) and fa.trend > 0 -> {true, "average level is up this week"}
      is_number(this) and this >= 7 -> {true, "mostly falling asleep with little help"}
      true -> {false, "not trending down yet"}
    end
  end

  defp auto("falling-asleep-alone", _ctx), do: {false, "track how they fall asleep"}

  defp auto("seen-self-sleep", %{falling_asleep: %{weeks: weeks}}) do
    best =
      weeks |> Enum.map(& &1.independent_share) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> 0 end)

    {best > 0, if(best > 0, do: "some sleeps at level 8–9", else: "no level 8–9 sleeps yet")}
  end

  defp auto("seen-self-sleep", _ctx), do: {false, nil}

  defp auto("not-every-waking-fed", %{nights: %{nights: nights}}) do
    recent = Enum.take(nights, 7)
    ok = Enum.any?(recent, &(&1.wakings > &1.feeds))
    {ok, if(ok, do: "a night with more wakings than feeds", else: "every waking ended in a feed")}
  end

  defp auto("fewer-wakings", %{nights: %{nights: nights}}),
    do: improving(nights, & &1.wakings, "wakings")

  defp auto("fewer-night-feeds", %{nights: %{nights: nights}}),
    do: improving(nights, & &1.feeds, "night feeds")

  defp auto("cues-and-windows", %{habits: %{week: %{cued: cued}}}),
    do: {cued >= 3, "#{cued} sleeps with a cue noted this week"}

  defp auto(_id, _ctx), do: {false, nil}

  # Last 3 nights' average below the 3 before (needs six nights).
  defp improving(nights, fun, label) do
    {recent, earlier} = nights |> Enum.map(fun) |> Enum.split(3)
    earlier = Enum.take(earlier, 3)

    if length(recent) == 3 and length(earlier) == 3 do
      {average(recent) < average(earlier),
       "#{format(average(recent))} vs #{format(average(earlier))} #{label} a night"}
    else
      {false, "needs 6 nights"}
    end
  end

  ## Troubleshooting hints -----------------------------------------------------

  defp hint("t-fall-asleep", %{falling_asleep: %{this_week: %{mean_level: level}}})
       when is_number(level),
       do: "This week's average level is #{format(level)} of 9."

  defp hint("t-calories", %{nights: %{nights: [_ | _] = nights}}) do
    avg = average(Enum.map(Enum.take(nights, @recent), & &1.feeds))
    if avg > 1, do: "#{format(avg)} night feeds a night lately.", else: nil
  end

  defp hint(_id, _ctx), do: nil

  defp average(list), do: Enum.sum(list) / max(length(list), 1)
  defp format(n), do: :erlang.float_to_binary(n * 1.0, decimals: 1)

  defp local_minutes(child, at) do
    local = DateTime.shift_zone!(at, child.timezone)
    local.hour * 60 + local.minute
  end
end
