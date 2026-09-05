defmodule Trygg.Growth.ReminderNotification do
  @moduledoc """
  Bookkeeping row: the last time a child's caregivers were emailed that a
  routine weight check was overdue. One row per child, kept so a restart or a
  frequent scheduler tick can't re-send — a fresh reminder only goes out once
  a full check interval has passed since the previous one.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "growth_reminder_notifications" do
    field :last_notified_on, :date
    field :last_measured_on, :date

    belongs_to :child, Trygg.Families.Child

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:last_notified_on, :last_measured_on])
    |> validate_required([:last_notified_on])
  end
end
