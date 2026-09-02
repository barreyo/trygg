defmodule Trygg.Repo.Migrations.CreateGrowthMeasurements do
  use Ecto.Migration

  def change do
    create table(:growth_measurements) do
      add :child_id, references(:children, on_delete: :delete_all), null: false
      add :logged_by_id, references(:users, on_delete: :nilify_all)
      add :measured_at, :utc_datetime, null: false
      add :weight_g, :float
      add :height_cm, :float
      add :note, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:growth_measurements, [:child_id, :measured_at])
  end
end
