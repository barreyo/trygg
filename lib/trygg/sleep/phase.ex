defmodule Trygg.Sleep.Phase do
  @moduledoc """
  Which stage of the sleep journey a child is in, by corrected age.

  The Taking Cara Babies guides are age-specific: newborn soothing and
  routines up to about 12 weeks, the "Navigating Months 3 & 4" plan from
  13 weeks, and optional active sleep training from 5 months. Features gate on
  this so a newborn is never shown night-feed weaning, and so Home can say what
  is coming next.

  Corrected age (`Trygg.Reports.Norms.corrected_age_days/2`) is used, so a baby
  born early moves through the phases on their due date, not their birthday.
  """

  alias Trygg.Families.Child
  alias Trygg.Reports.Norms

  # Boundaries in days of corrected age. 13 weeks starts the 3-4 month guide;
  # 5 months is where "The ABCs of Sleep" begins.
  @phases [
    %{id: :newborn, label: "Newborn", from_days: 0},
    %{id: :foundations, label: "Foundations", from_days: 13 * 7},
    %{id: :beyond, label: "5 months and beyond", from_days: 152}
  ]

  @doc """
  The phase for `child` on `date` (default: today in their time zone), or `nil`
  while they have no birth date yet.

  Returns `%{id, label, week, age_days, next}` where `next` is `nil` in the last
  phase, else `%{id, label, on, in_days}`: when the next phase starts.
  """
  def for_child(%Child{} = child, date \\ nil) do
    date = date || Child.local_today(child)

    case Norms.corrected_age_days(child, date) do
      nil -> nil
      age_days -> build(age_days, date)
    end
  end

  @doc "All phases, in order."
  def all, do: @phases

  @doc """
  Every phase with the date it starts and whether it is `:past`, `:current` or
  `:upcoming` for `child` on `date` (default: today), or `[]` without a birth
  date. A phase's `starts_on` can be before the birth date for the first phase
  of a baby born early; it is the date their corrected age reaches the boundary.
  """
  def timeline(%Child{} = child, date \\ nil) do
    date = date || Child.local_today(child)

    case Norms.corrected_age_days(child, date) do
      nil ->
        []

      age_days ->
        current = build(age_days, date).id

        for phase <- @phases do
          %{
            id: phase.id,
            label: phase.label,
            starts_on: Date.add(date, phase.from_days - age_days),
            state: state(phase, current, age_days)
          }
        end
    end
  end

  defp state(%{id: id}, id, _age_days), do: :current
  defp state(%{from_days: from}, _current, age_days) when from < age_days, do: :past
  defp state(_phase, _current, _age_days), do: :upcoming

  defp build(age_days, date) do
    current = @phases |> Enum.filter(&(&1.from_days <= age_days)) |> List.last()
    next = Enum.find(@phases, &(&1.from_days > age_days))

    %{
      id: current.id,
      label: current.label,
      week: div(age_days, 7),
      age_days: age_days,
      next:
        next &&
          %{
            id: next.id,
            label: next.label,
            on: Date.add(date, next.from_days - age_days),
            in_days: next.from_days - age_days
          }
    }
  end
end
