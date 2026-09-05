defmodule Trygg.Growth.ReminderNotification do
  @moduledoc """
  Bookkeeping row: the last time a caregiver was emailed that a child's
  routine weight check was overdue. One row per `{child, caregiver}`, kept so
  a re-run can't re-send — a fresh reminder only goes out once that
  caregiver's check interval has passed since the previous one.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "growth_reminder_notifications" do
    field :last_notified_on, :date
    field :last_measured_on, :date

    belongs_to :child, Trygg.Families.Child
    belongs_to :user, Trygg.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:last_notified_on, :last_measured_on])
    |> validate_required([:last_notified_on])
  end
end
