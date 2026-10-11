defmodule Trygg.Sleep.Approaches do
  @moduledoc """
  Which way to teach independent sleep: the choice *Precious Little Sleep*
  walks you through, as a suggestion from what the log shows.

  The book's order is to start gradual (a SWAP, `Trygg.Sleep.Swap`) and move to
  the Sleep Learning Independence Plan (`Trygg.Sleep.Slip`) if that doesn't work
  or you've nothing left in the tank. "The ABCs of Sleep" (`Trygg.Sleep.Abcs`) is
  the other structured way, with its night-weaning table. Under about two
  months, none of them: use the power tools.

  `recommend/1` only suggests; every plan stays available once its own age
  and pre-flight gates are met.
  """

  alias Trygg.Sleep.Plan

  @min_swap_days 61
  @min_slip_days 122
  @sucker_share 0.5
  @min_measured 5

  @doc """
  `recommend(ctx)` for `%{age_days, habits, falling_asleep, plans}` (corrected age,
  `Trygg.Reports.SleepHabits.summarize/4`, `Trygg.Reports.FallingAsleep.summarize/3` and
  the child's earlier `Trygg.Sleep.Plan`s; any may be `nil`/`[]`).

  Returns `%{suggested, type, variant, reasons}`:

    * `suggested` — `:tools` (too young), `:swap`, or `:slip` (a gradual plan has
      been tried already and they're old enough).
    * `type` — the kind of baby the log suggests: `:sucker` (often fed to
      sleep), `:cuddler` (held to sleep), `:motion` (rocked or patted), `:independent`
      (mostly settling alone) or `nil` without data.
    * `variant` — the SWAP variant that fits that type.
    * `reasons` — why, in a sentence or two each; `why` is the one about this
      baby (or a hint to note how they fall asleep).
  """
  def recommend(ctx) do
    age = ctx[:age_days]
    type = baby_type(ctx[:habits], ctx[:falling_asleep])
    variant = variant(type, age)
    tried? = tried_before?(ctx[:plans] || [])

    {suggested, reasons} =
      cond do
        not is_integer(age) or age < @min_swap_days ->
          {:tools,
           [
             "Too young for a plan: it's the time for soothing, not teaching. Use the sleep tools and keep nights safe."
           ]}

        tried? and age >= @min_slip_days ->
          {:slip,
           [
             "A gradual plan hasn't done it, so the book's next step is the Sleep Learning Independence Plan.",
             "The ABCs of Sleep is the other structured option, with a night-weaning table."
           ]}

        true ->
          {:swap,
           [
             "The book's advice is to start gradual and commit to one plan for 5–7 nights.",
             "If a gradual plan doesn't work, or you've nothing left to give, the next step is SLIP."
           ]}
      end

    %{
      suggested: suggested,
      type: type,
      variant: variant,
      reasons: reasons ++ type_reasons(type),
      why: hd(type_reasons(type))
    }
  end

  @doc "The kind of baby the log suggests, or `nil` without enough data."
  def baby_type(habits, falling) do
    cond do
      fed_share(habits) >= @sucker_share ->
        :sucker

      is_number(mean_level(falling)) ->
        level = mean_level(falling)

        cond do
          level <= 3.0 -> :cuddler
          level <= 5.0 -> :motion
          true -> :independent
        end

      true ->
        nil
    end
  end

  # Share of sleeps (with a feed in the six hours before) that began within 10
  # minutes of a feed; zero until there are enough of them to mean anything.
  defp fed_share(%{week: %{measured: measured, fed_to_sleep: fed}})
       when is_integer(measured) and measured >= @min_measured and is_integer(fed),
       do: fed / measured

  defp fed_share(_), do: 0.0

  defp mean_level(%{this_week: %{mean_level: level}}) when is_number(level), do: level

  defp mean_level(%{weeks: weeks}) when is_list(weeks) do
    weeks |> Enum.reverse() |> Enum.find_value(& &1.mean_level)
  end

  defp mean_level(_), do: nil

  defp variant(:sucker, _age), do: :pull_out
  defp variant(:cuddler, _age), do: :chair
  defp variant(:motion, age) when is_integer(age) and age >= 182, do: :pat
  defp variant(:motion, _age), do: :jiggle
  defp variant(_type, _age), do: :fuss_it_out

  defp tried_before?(plans) do
    Enum.any?(plans, fn %Plan{definition: definition, status: status} ->
      definition == :swap and status in [:stopped, :completed]
    end)
  end

  defp type_reasons(:sucker),
    do: [
      "Many of their sleeps start right after a feed, so sucking is likely the habit to unpick."
    ]

  defp type_reasons(:cuddler),
    do: ["They're mostly helped to sleep in arms, so it's your body they need."]

  defp type_reasons(:motion),
    do: ["They're mostly rocked or patted to sleep, so motion is the habit to fade."]

  defp type_reasons(:independent),
    do: ["They're already settling with little help. You may not need a plan at all."]

  defp type_reasons(nil),
    do: [
      "Note how they fall asleep when they start a sleep and this will suggest a plan that fits."
    ]
end
