defmodule Trygg.Repo.Migrations.AddVitaminDReminderToChildren do
  use Ecto.Migration

  def change do
    alter table(:children) do
      # Opt-in: the daily vitamin D drop reminder is off until a caregiver
      # turns it on in the child's settings.
      add :vitamin_d_reminder, :boolean, null: false, default: false
      # The child-local date the evening reminder last went out, so the
      # scan sends at most one per day.
      add :vitamin_d_reminded_on, :date
    end
  end
end
