defmodule Trygg.Repo.Migrations.CreateDevicePins do
  use Ecto.Migration

  def up do
    # Which devices a member has on their own Today screen. A device is the family's, but
    # whether it shows on Today is a personal choice, so it lives per user.
    create table(:device_pins) do
      add :device_id, references(:devices, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:device_pins, [:user_id, :device_id])
    create index(:device_pins, [:device_id])

    # Everyone who could see a pinned device keeps seeing it; each can unpin their own.
    execute """
    INSERT INTO device_pins (device_id, user_id, inserted_at)
    SELECT d.id, m.user_id, NOW()
    FROM devices d
    JOIN memberships m ON m.family_id = d.family_id
    WHERE d.on_today
    """

    alter table(:devices) do
      remove :on_today
    end
  end

  def down do
    alter table(:devices) do
      add :on_today, :boolean, null: false, default: false
    end

    # A device counts as pinned if anyone had it pinned.
    execute "UPDATE devices SET on_today = true WHERE id IN (SELECT device_id FROM device_pins)"

    drop table(:device_pins)
  end
end
