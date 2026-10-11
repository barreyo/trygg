defmodule Trygg.Sleep.Schedules do
  @moduledoc """
  Age-based day shapes from the Taking Cara Babies guides: how many naps, how
  long to stay awake between them, how much daytime sleep, and the bedtime
  window, for 3–4 months (the "Navigating Months 3 & 4" guide) and for 5 months
  onward ("The ABCs of Sleep" nap section).

  These are guides, not rules; the child's own pattern wins in
  `Trygg.Reports.Insights`. `plan_day/3` turns a table into a day from a wake-up
  time, for the Sleep toolkit's "by the guide" schedule.
  """

  alias Trygg.Families.Child

  # Ages are corrected days. Durations are minutes. `windows` is the usual wake
  # window before each nap in a day of `nap_minutes`'s length, then the stretch
  # between the last nap's end and bedtime (`bed_gap`).
  @tables [
    %{
      id: :three_four_months,
      label: "3–4 months",
      from_days: 91,
      naps: "3–4",
      wake_window: {75, 120},
      daytime_goal: {210, 270},
      daytime_cap: 300,
      bedtime: {19 * 60, 20 * 60},
      windows: [75, 90, 90, 90],
      nap_minutes: [60, 75, 60, 30],
      bed_gap: {100, 120},
      feeds: "every 2–4 hours"
    },
    %{
      id: :five_to_seven_months,
      label: "5–7 months",
      from_days: 152,
      naps: "3",
      wake_window: {120, 180},
      daytime_goal: {180, 210},
      daytime_cap: 240,
      bedtime: {18 * 60 + 30, 20 * 60},
      windows: [120, 150, 150],
      nap_minutes: [75, 60, 40],
      bed_gap: {150, 180},
      feeds: "every 2.5–3.5 hours"
    },
    %{
      id: :seven_to_fourteen_months,
      label: "7–14 months",
      from_days: 213,
      naps: "2",
      wake_window: {180, 240},
      daytime_goal: {150, 180},
      daytime_cap: 210,
      bedtime: {18 * 60 + 30, 20 * 60},
      windows: [165, 195],
      nap_minutes: [80, 80],
      bed_gap: {210, 240},
      feeds: "every 2.5–3.5 hours"
    },
    %{
      id: :one_nap,
      label: "12–24 months",
      from_days: 456,
      naps: "1",
      wake_window: {240, 360},
      daytime_goal: {120, 180},
      daytime_cap: 180,
      bedtime: {18 * 60 + 30, 20 * 60},
      windows: [300],
      nap_minutes: [120],
      bed_gap: {270, 300},
      feeds: "by hunger cues"
    }
  ]

  @doc "Every table, youngest first."
  def tables, do: @tables

  @doc """
  The table for a corrected age in days, or `nil` before 3 months (13 weeks),
  where the newborn guidance has no schedule to follow.
  """
  def for_age(age_days) when is_integer(age_days) do
    @tables |> Enum.filter(&(&1.from_days <= age_days)) |> List.last()
  end

  def for_age(_), do: nil

  @doc """
  A day built from `table` starting at `wake_at` (a `DateTime`): the naps, then
  bedtime, as `%{items, bedtime, notes}`. Each item is
  `%{kind: :nap | :bed, ordinal, start, end}`. Bedtime is the last nap's end plus
  the middle of `bed_gap`, held inside the table's bedtime window (and not
  before 18:00); `notes` says when it had to be held.
  """
  def plan_day(%Child{} = child, table, %DateTime{} = wake_at) do
    {naps, last_end} =
      table.windows
      |> Enum.zip(table.nap_minutes)
      |> Enum.with_index(1)
      |> Enum.map_reduce(wake_at, fn {{window, length}, i}, from ->
        start = DateTime.add(from, window * 60, :second)
        finish = DateTime.add(start, length * 60, :second)
        {%{kind: :nap, ordinal: i, start: start, end: finish}, finish}
      end)

    {gap_lo, gap_hi} = table.bed_gap
    raw = DateTime.add(last_end, div(gap_lo + gap_hi, 2) * 60, :second)
    {bed, notes} = hold_in_window(child, table, raw)

    %{
      items: naps ++ [%{kind: :bed, ordinal: nil, start: bed, end: bed}],
      bedtime: bed,
      notes: notes
    }
  end

  defp hold_in_window(child, table, raw) do
    {lo, hi} = table.bedtime
    minutes = local_minutes(child, raw)
    date = raw |> DateTime.shift_zone!(child.timezone) |> DateTime.to_date()

    cond do
      minutes > hi ->
        {at(child, date, hi), [:late_naps]}

      minutes < 18 * 60 ->
        {at(child, date, 18 * 60), [:early_bedtime]}

      minutes < lo ->
        {raw, [:early_bedtime]}

      true ->
        {raw, []}
    end
  end

  @doc "Minutes since local midnight for `at`."
  def local_minutes(%Child{} = child, %DateTime{} = at) do
    local = DateTime.shift_zone!(at, child.timezone)
    local.hour * 60 + local.minute
  end

  defp at(child, date, minutes),
    do: Child.at_local(child, date, Time.new!(div(minutes, 60), rem(minutes, 60), 0))
end
