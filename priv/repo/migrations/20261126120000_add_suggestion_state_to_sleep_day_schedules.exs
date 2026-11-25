defmodule Trygg.Repo.Migrations.AddSuggestionStateToSleepDaySchedules do
  use Ecto.Migration

  def change do
    alter table(:sleep_day_schedules) do
      # Suggestions turned down: "<id>:<value>" => the ISO date it was dismissed.
      add :dismissed, :map, null: false, default: %{}
      # Suggestions accepted, newest last: %{"on", "id", "title"}.
      add :history, {:array, :map}, null: false, default: []
    end
  end
end
