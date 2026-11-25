defmodule Trygg.Repo.Migrations.CreateSleepDaySchedules do
  use Ecto.Migration

  def change do
    # The caregivers' own settings for the sleep day, one row per child. Every
    # column is optional: a null (or a null slot in an array) means "follow the
    # guide for their age", so only what someone has set is stored.
    create table(:sleep_day_schedules) do
      add :child_id, references(:children, on_delete: :delete_all), null: false
      add :updated_by_id, references(:users, on_delete: :nilify_all)
      # Minutes after local midnight.
      add :wake_minutes, :integer
      add :bedtime_minutes, :integer
      add :nap_count, :integer
      # Minutes awake before each nap, and the length of each nap, by slot.
      add :wake_windows, {:array, :integer}, null: false, default: []
      add :nap_lengths, {:array, :integer}, null: false, default: []
      # The guide (`Schedules` table or `AgeGuide` band) in force when this was
      # saved, so the page can say when the guide has moved on.
      add :guide_id, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:sleep_day_schedules, [:child_id])
  end
end
