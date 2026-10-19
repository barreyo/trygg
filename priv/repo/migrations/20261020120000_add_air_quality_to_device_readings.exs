defmodule Trygg.Repo.Migrations.AddAirQualityToDeviceReadings do
  use Ecto.Migration

  def change do
    alter table(:device_readings) do
      # Bosch BSEC's static IAQ (0 clean .. 500 bad) and how far it has calibrated to the room
      # (0 still learning .. 3 calibrated), plus its CO2 and breath-VOC equivalents. Unlike the
      # raw gas resistance, these are corrected for humidity and measured against a learned baseline.
      add :iaq, :float
      add :iaq_accuracy, :integer
      add :co2_ppm, :float
      add :voc_ppm, :float
    end
  end
end
