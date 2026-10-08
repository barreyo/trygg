defmodule Trygg.Repo.Migrations.AddTrackedTypesToChildren do
  use Ecto.Migration

  def change do
    alter table(:children) do
      # Which trackers the Home screen offers for this child. Stored on the
      # child so every caregiver sees the same layout; everything on by default.
      add :tracked_types, {:array, :string}, null: false, default: ["feeding", "diaper", "sleep"]
    end
  end
end
