defmodule Trygg.Sleep.NightWake do
  @moduledoc """
  One night waking being worked through in night mode: which method, the step
  they're on and when it began, and how it ended. See `Trygg.Sleep.NightWakes`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @methods [:cries, :sit_back, :abcs]
  @kinds [:waking, :bedtime]
  @outcomes [:settled, :fed, :stopped]

  schema "night_wakes" do
    field :method, Ecto.Enum, values: @methods
    field :started_at, :utc_datetime
    field :step, :integer, default: 0
    field :step_started_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :outcome, Ecto.Enum, values: @outcomes
    # The step they settled at, for the "settled at step 4" picture.
    field :settled_step, :integer
    # "bedtime" for the put-down at the start of a night, else "waking".
    field :kind, Ecto.Enum, values: @kinds, default: :waking
    # Timestamped happenings in a check-in waking (see `Trygg.Sleep.Checkins`).
    field :events, {:array, :map}, default: []
    field :cry_seconds, :integer

    belongs_to :child, Trygg.Families.Child
    belongs_to :started_by, Trygg.Accounts.User
    belongs_to :plan, Trygg.Sleep.Plan

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(wake, attrs) do
    wake
    |> cast(attrs, [
      :method,
      :started_at,
      :step,
      :step_started_at,
      :ended_at,
      :outcome,
      :settled_step,
      :kind,
      :events,
      :cry_seconds,
      :plan_id
    ])
    |> validate_required([:method, :started_at, :step, :step_started_at])
    |> validate_number(:step, greater_than_or_equal_to: 0)
    |> unique_constraint(:child_id, name: :night_wakes_one_active_per_child)
  end

  @doc "Whether the waking is still in progress."
  def active?(%__MODULE__{ended_at: nil}), do: true
  def active?(%__MODULE__{}), do: false

  def outcomes, do: @outcomes
end
