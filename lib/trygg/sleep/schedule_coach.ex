defmodule Trygg.Sleep.ScheduleCoach do
  @moduledoc """
  Suggested changes to a child's sleep day, from what the log shows against what
  the schedule says. Nothing here changes the schedule: each suggestion carries a
  `change` the caregiver can apply or turn down (`Trygg.Sleep.DaySchedules`).

  What it looks for, in this order:

    * **Bedtime** later than the age's window: ease it 15 minutes earlier, once
      a day, from whatever it is now (the guide's "10–15 minutes each evening").
    * **Naps a day** lower than the schedule has for a week: drop one.
    * **Wake windows** that the log has run longer (and the nap after them held
      up) or shorter than the schedule's, by 15 minutes or more: move them,
      within the age's range.
    * **Wake-up** that has settled somewhere other than the one they chose.

  It stays quiet without about a week of log, and goes quiet altogether (`hold`)
  around a clock change, or in a rough patch near a regression age, since
  changing the day then mistakes a blip for a pattern. It never touches feeds or
  anything gated by a pediatrician's go-ahead.

  Pure: takes what it needs in `ctx` (see `suggest/1`).
  """

  alias Trygg.Sleep.DaySchedule

  @min_days 7
  @min_samples 5
  @bedtime_step 15
  @window_gap 15
  @dismiss_days 14
  @rough_findings [:early_wake, :night_gap, :sleep_debt, :short_naps]
  @max_shown 3

  @doc "How many days a dismissed suggestion stays hidden."
  def dismiss_days, do: @dismiss_days

  @doc """
  `suggest(ctx)` where `ctx` is

      %{effective: DaySchedules.effective/4 map, schedule: DaySchedule | nil,
        insights: Trygg.Reports.Insights summary, findings: [finding ids],
        today: Date, dismissed: %{key => iso date}, history: [%{"on", "id"}]}

  Returns `%{ready?, hold, suggestions}`. `ready?` is false until there's about
  a week of log. `hold` is `nil` or `%{reason: :clock_change | :rough_patch}`,
  in which case `suggestions` is empty. Each suggestion is

      %{id, key, title, detail, change}

  with `change` the attributes to lay over the schedule (`DaySchedules.accept/3`
  merges them) and `key` an id that includes the proposed value, so turning one
  down doesn't hide a different one later.
  """
  def suggest(%{effective: nil}), do: %{ready?: false, hold: nil, suggestions: []}

  def suggest(%{insights: insights} = ctx) do
    ready? = insights.ready? and insights.sample_days >= @min_days

    cond do
      not ready? ->
        %{ready?: false, hold: nil, suggestions: []}

      hold = hold(ctx.findings) ->
        %{ready?: true, hold: hold, suggestions: []}

      true ->
        suggestions =
          [bedtime(ctx), nap_count(ctx), wake_windows(ctx), wake_anchor(ctx)]
          |> Enum.reject(&is_nil/1)
          |> Enum.reject(&dismissed?(&1, ctx))
          |> Enum.take(@max_shown)

        %{ready?: true, hold: nil, suggestions: suggestions}
    end
  end

  defp hold(findings) do
    cond do
      :dst in findings ->
        %{reason: :clock_change}

      :regression_window in findings and Enum.any?(@rough_findings, &(&1 in findings)) ->
        %{reason: :rough_patch}

      true ->
        nil
    end
  end

  defp dismissed?(%{key: key}, %{dismissed: dismissed, today: today}) do
    case dismissed[key] && Date.from_iso8601(dismissed[key]) do
      {:ok, on} -> Date.diff(today, on) < @dismiss_days
      _ -> false
    end
  end

  ## Bedtime ------------------------------------------------------------------

  defp bedtime(%{effective: %{mode: :guide, table: table}} = ctx) do
    {_lo, hi} = table.bedtime
    pinned = ctx.schedule && ctx.schedule.bedtime_minutes
    usual = ctx.insights.bedtime && ctx.insights.bedtime.median_minutes
    current = pinned || (usual && round(usual))

    if is_integer(current) and current > hi and not accepted_today?(ctx, :bedtime_earlier) do
      target = max(current - @bedtime_step, hi)

      %{
        id: :bedtime_earlier,
        key: "bedtime_earlier:#{target}",
        title: "Ease bedtime earlier",
        detail:
          "It's #{clock(current)}, after the #{clock(elem(table.bedtime, 0))}–#{clock(hi)} window for this age. " <>
            "The guide moves it 10–15 minutes earlier each evening until it's in the window. Tonight: #{clock(target)}.",
        change: %{bedtime_minutes: target}
      }
    end
  end

  defp bedtime(_ctx), do: nil

  defp accepted_today?(%{history: history, today: today}, id) do
    id = Atom.to_string(id)
    on = Date.to_iso8601(today)
    Enum.any?(history, &(&1["id"] == id and &1["on"] == on))
  end

  ## Naps a day ---------------------------------------------------------------

  defp nap_count(%{effective: %{mode: :guide, nap_count: %{value: count}}} = ctx)
       when count >= 2 do
    %{n: n, median: median} = ctx.insights.naps.count

    if n >= @min_days and is_number(median) and median <= count - 1 do
      target = count - 1

      %{
        id: :nap_count,
        key: "nap_count:#{target}",
        title: "Plan #{target} naps a day",
        detail:
          "They've been taking about #{format_number(median)} a day for the last #{n} days, and the schedule has #{count}. " <>
            "Plan the day around #{target} so the last window doesn't run long.",
        change: %{nap_count: target}
      }
    end
  end

  defp nap_count(_ctx), do: nil

  ## Wake windows -------------------------------------------------------------

  defp wake_windows(%{effective: %{mode: :guide, slots: slots, table: table}} = ctx) do
    {lo, hi} = table.wake_window

    moves =
      for slot <- slots,
          obs = observed_window(ctx.insights, slot.ordinal),
          nap_after = observed_nap(ctx.insights, slot.ordinal),
          move = window_move(slot.window.minutes, obs, nap_after, lo, hi),
          do: Map.merge(move, %{ordinal: slot.ordinal, observed: obs})

    if moves != [] do
      pinned = (ctx.schedule && ctx.schedule.wake_windows) || []
      list = Enum.reduce(moves, pinned, &put_slot(&2, &1.ordinal - 1, &1.to))

      %{
        id: :wake_windows,
        key: "wake_windows:" <> Enum.map_join(moves, ",", &"#{&1.ordinal}=#{&1.to}"),
        title: window_title(moves),
        detail:
          Enum.map_join(moves, " ", fn m ->
            "Nap #{m.ordinal}: #{m.from} → #{m.to} min (they've been awake about #{m.observed})."
          end) <> " Within the #{lo}–#{hi} minutes the guide gives for this age.",
        change: %{wake_windows: list}
      }
    end
  end

  defp wake_windows(_ctx), do: nil

  defp window_move(current, observed, nap_after, lo, hi) do
    target = observed |> clamp(lo, hi) |> div(5) |> Kernel.*(5) |> clamp(lo, hi)
    diff = observed - current

    cond do
      abs(diff) < @window_gap or abs(diff) < current * 0.15 -> nil
      target == current -> nil
      # Longer only while the naps after those windows are holding up.
      diff > 0 and nap_after < 40 -> nil
      true -> %{from: current, to: target}
    end
  end

  defp window_title(moves) do
    cond do
      Enum.all?(moves, &(&1.to > &1.from)) -> "Stretch the wake windows"
      Enum.all?(moves, &(&1.to < &1.from)) -> "Shorten the wake windows"
      true -> "Adjust the wake windows"
    end
  end

  defp observed_window(insights, ordinal) do
    case Enum.find(insights.wake_windows.by_ordinal, &(&1.ordinal == ordinal)) do
      %{n: n, median: median} when n >= @min_samples and is_number(median) -> round(median / 60)
      _ -> nil
    end
  end

  defp observed_nap(insights, ordinal) do
    case Enum.find(insights.naps.by_ordinal, &(&1.ordinal == ordinal)) do
      %{n: n, median: median} when n >= @min_samples and is_number(median) -> round(median / 60)
      _ -> nil
    end
  end

  defp put_slot(list, i, value) do
    list = list ++ List.duplicate(nil, max(i + 1 - length(list), 0))
    List.replace_at(list, i, value)
  end

  ## Wake-up ------------------------------------------------------------------

  defp wake_anchor(%{schedule: %DaySchedule{wake_minutes: pinned}} = ctx)
       when is_integer(pinned) do
    case ctx.insights.morning_wake do
      %{n: n, median_minutes: median, iqr_minutes: iqr}
      when n >= @min_days and is_number(median) and is_number(iqr) and iqr <= 30 ->
        target = round(median / 5) * 5

        if abs(target - pinned) >= 30 do
          %{
            id: :wake_anchor,
            key: "wake_anchor:#{target}",
            title: "Their wake-up has moved",
            detail:
              "You set #{clock(pinned)}, and they've been waking around #{clock(target)}, steadily, for #{n} days. " <>
                "Use that, or keep yours if you're steering it back.",
            change: %{wake_minutes: target}
          }
        end

      _ ->
        nil
    end
  end

  defp wake_anchor(_ctx), do: nil

  ## Helpers ------------------------------------------------------------------

  defp clamp(value, lo, hi), do: value |> max(lo) |> min(hi)

  defp clock(minutes), do: Trygg.TimeFormat.clock(minutes)

  defp format_number(n) when is_float(n),
    do: n |> Float.round(1) |> to_string() |> String.trim_trailing(".0")

  defp format_number(n), do: to_string(n)
end
