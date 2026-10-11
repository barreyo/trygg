defmodule Trygg.Sleep.NapTraining do
  @moduledoc """
  When to start working on naps after the ABCs plan's nights, and how: the
  guide's rule is **nights first**. Finish at least night 1 before nap training;
  night sleep is learned first and day sleep (which uses a different part of the
  brain) follows, so for the first 14 nights keep doing what you do for naps.

  `readiness/1` checks the guide's signs that it's time (any one is enough),
  ticking those it can from the log; `steps/0` is the guide's N.A.P. summary
  (naptime routine, awake, pop-in) and `tips/0` its short answers.
  """

  alias Trygg.Families.Child

  @ten_months_days 304
  @early_wake_minutes 5 * 60 + 30
  @short_nap_seconds 40 * 60

  # {id, text, auto?}
  @signs [
    {"n-age", "They're 10 months or older and you feel ready.", true},
    {"n-nights", "They've slept 11–12 hours a night for 10 of the last 14 nights.", true},
    {"n-day-sleep", "Too little daytime sleep seems to be causing night wakings.", false},
    {"n-early", "Early mornings are still rough (waking before about 5:30) after the plan.",
     true},
    {"n-battle", "Naps have become a battle: 45–60 minutes trying to get a 30-minute nap.",
     false},
    {"n-short", "Naps are under 40 minutes each.", true}
  ]

  @steps [
    %{
      letter: "N",
      name: "Naptime routine",
      detail:
        "A 5–10 minute version of the bedtime routine, the same every nap: diaper, a book, a rock, then down awake."
    },
    %{
      letter: "A",
      name: "Awake",
      detail: "Put them down awake for the nap. Don't feed, rock or bounce them to sleep."
    },
    %{
      letter: "P",
      name: "Pop-in",
      detail:
        "Pop in as needed, 10–20 seconds each, on the same 5, 10, 15 minute schedule (or stretch it). Keep in mind it can take 2–4 weeks."
    }
  ]

  @tips [
    "Give them 60–75 minutes to fall asleep. If they haven't by then, get them out at a quiet moment, do something active, and try again about an hour later.",
    "After a 20–25 minute nap, let them stay in the crib another 15–25 minutes to see if they go back to sleep. Don't go in during that time. Either way keep a full wake window before the next nap.",
    "Never let a nap run past 2 hours; wake them. Keep daytime sleep within the age's cap.",
    "Flexible routines, not rigid schedules. For the first two weeks of nap training you may need to be a bit stricter.",
    "A third nap is often a 30–45 minute catnap to make it to bedtime. If it's a battle, an 'oops nap' on the go, in the stroller or in your arms is fine."
  ]

  @doc "The signs, as `{id, text}`."
  def signs, do: Enum.map(@signs, fn {id, text, _auto} -> {id, text} end)

  @doc "The N.A.P. steps."
  def steps, do: @steps

  @doc "Short answers to common nap questions."
  def tips, do: @tips

  @doc """
  `%{signs, any?}` for `%{child, nights, nap_medians}`: `nights` is a
  `Trygg.Reports.Nights` summary (ideally 14 nights) and `nap_medians` the median
  length in seconds of each nap of the day (a list, possibly empty). Each sign is
  `%{id, text, checked?, auto?, detail}`; manual signs follow `child.sleep_checks`.
  """
  def readiness(%{child: %Child{} = child} = ctx) do
    ticks = child.sleep_checks || %{}

    signs =
      for {id, text, auto?} <- @signs do
        {checked?, detail} = if auto?, do: auto(id, ctx), else: {Map.has_key?(ticks, id), nil}
        %{id: id, text: text, checked?: checked?, auto?: auto?, detail: detail}
      end

    %{signs: signs, any?: Enum.any?(signs, & &1.checked?)}
  end

  defp auto("n-age", %{child: child, age_days: age}) when is_integer(age) do
    _ = child
    {age >= @ten_months_days, "#{div(age, 30)} months old"}
  end

  defp auto("n-age", _ctx), do: {false, nil}

  defp auto("n-nights", %{nights: %{nights: nights}}) do
    long = Enum.count(nights, &(DateTime.diff(&1.wake, &1.bedtime, :second) >= 11 * 3600))
    {long >= 10 and length(nights) >= 10, "#{long} of the last #{length(nights)} nights"}
  end

  defp auto("n-early", %{child: child, nights: %{nights: nights}}) do
    recent = Enum.take(nights, 7)

    early =
      Enum.count(recent, fn night ->
        local = DateTime.shift_zone!(night.wake, child.timezone)
        local.hour * 60 + local.minute < @early_wake_minutes
      end)

    {early >= 3, "#{early} of the last #{length(recent)} mornings before 5:30"}
  end

  defp auto("n-short", %{nap_medians: [_ | _] = medians}) do
    {Enum.all?(medians, &(&1 < @short_nap_seconds)),
     "typical naps #{div(Enum.min(medians), 60)}–#{div(Enum.max(medians), 60)} min"}
  end

  defp auto(_id, _ctx), do: {false, nil}
end
