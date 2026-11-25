defmodule Trygg.Sleep.DaySchedule do
  @moduledoc """
  What a family has chosen for their child's sleep day: a wake-up time, a
  bedtime, how many naps, and the wake window and length of each. Every field is
  optional; what's `nil` follows the guide for the child's age
  (`Trygg.Sleep.DaySchedules.effective/4` merges the two).

  Times are minutes after local midnight, durations minutes. `wake_windows` and
  `nap_lengths` are by slot (the first nap is slot 0), with `nil` for a slot that
  follows the guide.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @max_naps 5

  schema "sleep_day_schedules" do
    field :wake_minutes, :integer
    field :bedtime_minutes, :integer
    field :nap_count, :integer
    field :wake_windows, {:array, :integer}, default: []
    field :nap_lengths, {:array, :integer}, default: []
    field :guide_id, :string
    # Suggestions turned down ("<id>:<value>" => ISO date) and accepted
    # (`%{"on", "id", "title"}`, newest last). Set by `DaySchedules`, never cast.
    field :dismissed, :map, default: %{}
    field :history, {:array, :map}, default: []

    belongs_to :child, Trygg.Families.Child
    belongs_to :updated_by, Trygg.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [
      :wake_minutes,
      :bedtime_minutes,
      :nap_count,
      :wake_windows,
      :nap_lengths,
      :guide_id
    ])
    |> validate_number(:wake_minutes, greater_than_or_equal_to: 0, less_than_or_equal_to: 12 * 60)
    |> validate_number(:bedtime_minutes,
      greater_than_or_equal_to: 15 * 60,
      less_than_or_equal_to: 24 * 60 - 1
    )
    |> validate_number(:nap_count, greater_than_or_equal_to: 1, less_than_or_equal_to: @max_naps)
    |> validate_slots(:wake_windows, 20..480)
    |> validate_slots(:nap_lengths, 10..240)
  end

  @doc "The most naps a day can have here."
  def max_naps, do: @max_naps

  @doc """
  Whether no choice is set, so the day is the guide as it stands. (The row may
  still be kept for the suggestions it has dismissed or accepted.)
  """
  def empty?(%__MODULE__{} = schedule) do
    is_nil(schedule.wake_minutes) and is_nil(schedule.bedtime_minutes) and
      is_nil(schedule.nap_count) and Enum.all?(schedule.wake_windows, &is_nil/1) and
      Enum.all?(schedule.nap_lengths, &is_nil/1)
  end

  defp validate_slots(changeset, field, range) do
    slots = get_field(changeset, field) || []

    cond do
      length(slots) > @max_naps ->
        add_error(changeset, field, "no more than #{@max_naps} naps")

      Enum.any?(slots, &(not is_nil(&1) and &1 not in range)) ->
        add_error(changeset, field, "must be between #{range.first} and #{range.last} minutes")

      true ->
        changeset
    end
  end
end
