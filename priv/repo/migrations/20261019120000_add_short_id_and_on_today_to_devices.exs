defmodule Trygg.Repo.Migrations.AddShortIdAndOnTodayToDevices do
  use Ecto.Migration

  def up do
    alter table(:devices) do
      # Five digits the device shows on its own screen, so a caregiver can tell which
      # physical unit a row in the app is. Unique within the family.
      add :short_id, :integer
      # Whether the device is a widget on the Today screen.
      add :on_today, :boolean, null: false, default: false
    end

    # Devices registered before short ids existed. Multiplying by a number coprime to 90000
    # spreads them over 10000..99999 without two of them landing on the same id.
    execute "UPDATE devices SET short_id = 10000 + (id * 7919) % 90000"

    alter table(:devices) do
      modify :short_id, :integer, null: false
    end

    create constraint(:devices, :short_id_five_digits, check: "short_id BETWEEN 10000 AND 99999")
    create unique_index(:devices, [:family_id, :short_id])
  end

  def down do
    drop unique_index(:devices, [:family_id, :short_id])
    drop constraint(:devices, :short_id_five_digits)

    alter table(:devices) do
      remove :short_id
      remove :on_today
    end
  end
end
