defmodule Trygg.Growth.CheckReminder do
  @moduledoc """
  Decides whether a child is due for a routine weight check, following the
  CDC-endorsed well-child cadence in
  `Trygg.Reports.Norms.weight_check_interval_days/1`.

  Pure: hand it the child, its most recent weight `Measurement` (or `nil`
  when none has ever been logged) and the child's local `today`. The check
  is anchored on the last weigh-in, or — before the first one — on the birth
  date, so a brand-new baby whose weight is never entered still surfaces.
  """

  alias Trygg.Families.Child
  alias Trygg.Growth.Measurement
  alias Trygg.Reports.Norms

  @type t :: %{
          due?: boolean(),
          days_since: non_neg_integer(),
          overdue_days: non_neg_integer(),
          interval_days: pos_integer(),
          last_measured_on: Date.t() | nil,
          never_measured?: boolean()
        }

  @doc """
  Returns a status map, or `nil` when there is nothing to anchor on (no
  weight ever logged and no birth date on file).
  """
  @spec evaluate(Child.t(), Measurement.t() | nil, Date.t()) :: t() | nil
  def evaluate(%Child{} = child, latest_weight, %Date{} = today) do
    last_on = measured_on(child, latest_weight)
    anchor = last_on || child.birth_date

    if anchor && not Date.after?(anchor, today) do
      interval = Norms.weight_check_interval_days(Norms.age_days(child, today))
      days_since = Date.diff(today, anchor)

      %{
        due?: days_since >= interval,
        days_since: days_since,
        overdue_days: max(days_since - interval, 0),
        interval_days: interval,
        last_measured_on: last_on,
        never_measured?: is_nil(last_on)
      }
    end
  end

  defp measured_on(_child, nil), do: nil

  defp measured_on(%Child{timezone: tz}, %Measurement{measured_at: %DateTime{} = at}) do
    at |> DateTime.shift_zone!(tz) |> DateTime.to_date()
  end
end
