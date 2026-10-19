defmodule Trygg.Repo.Migrations.CreateDevices do
  use Ecto.Migration

  def change do
    create table(:devices) do
      add :family_id, references(:families, on_delete: :delete_all), null: false
      # What the device calls itself (its WiFi MAC address); how a repeat POST finds its row.
      add :hardware_id, :string, null: false
      # Nil until a caregiver names it ("Nursery"): a new device registers itself unnamed.
      add :name, :string
      add :model, :string
      add :last_seen_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:devices, [:family_id, :hardware_id])

    create table(:device_readings) do
      add :device_id, references(:devices, on_delete: :delete_all), null: false
      add :measured_at, :utc_datetime_usec, null: false
      add :temperature_c, :float
      add :humidity_pct, :float
      add :pressure_hpa, :float
      # Raw gas (VOC) sensor resistance. Falls as air quality worsens; only meaningful as a trend.
      add :gas_ohms, :float

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:device_readings, [:device_id, :measured_at])
    create index(:device_readings, [:measured_at])
  end
end
