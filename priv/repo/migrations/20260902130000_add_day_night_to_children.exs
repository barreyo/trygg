defmodule Trygg.Repo.Migrations.AddDayNightToChildren do
  use Ecto.Migration

  def change do
    alter table(:children) do
      add :day_start, :time, null: false, default: fragment("'08:00:00'")
      add :night_start, :time, null: false, default: fragment("'20:00:00'")
    end
  end
end
