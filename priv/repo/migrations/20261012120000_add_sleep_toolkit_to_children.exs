defmodule Trygg.Repo.Migrations.AddSleepToolkitToChildren do
  use Ecto.Migration

  def change do
    alter table(:children) do
      # The date a caregiver recorded that the pediatrician is fine with night
      # weaning / sleep training. Nothing in the toolkit starts without it.
      add :night_weaning_cleared_on, :date
      add :sleep_training_cleared_on, :date
      # Manually ticked checklist items: item id => the date it was ticked.
      add :sleep_checks, :map, null: false, default: %{}
    end
  end
end
