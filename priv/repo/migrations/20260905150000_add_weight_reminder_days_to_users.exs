defmodule Trygg.Repo.Migrations.AddWeightReminderDaysToUsers do
  use Ecto.Migration

  # NULL  -> follow the CDC well-child schedule (the default)
  # 0     -> weight-check reminders off for this caregiver
  # N > 0 -> remind after N days without a logged weight
  def change do
    alter table(:users) do
      add :weight_reminder_days, :integer
    end

    create constraint(:users, :weight_reminder_days_non_negative,
             check: "weight_reminder_days is null or weight_reminder_days >= 0"
           )
  end
end
