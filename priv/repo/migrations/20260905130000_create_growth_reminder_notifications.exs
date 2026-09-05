defmodule Trygg.Repo.Migrations.CreateGrowthReminderNotifications do
  use Ecto.Migration

  def change do
    create table(:growth_reminder_notifications) do
      add :child_id, references(:children, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :last_notified_on, :date, null: false
      add :last_measured_on, :date

      timestamps(type: :utc_datetime)
    end

    create unique_index(:growth_reminder_notifications, [:child_id, :user_id])
  end
end
