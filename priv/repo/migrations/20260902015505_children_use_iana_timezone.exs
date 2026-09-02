defmodule Trygg.Repo.Migrations.ChildrenUseIanaTimezone do
  use Ecto.Migration

  def up do
    alter table(:children) do
      add :timezone, :string, null: false, default: "America/Los_Angeles"
    end

    # Best-effort map of the fixed offsets we may have stored to a real zone.
    execute """
    UPDATE children SET timezone = CASE utc_offset_minutes
      WHEN -480 THEN 'America/Los_Angeles'
      WHEN -420 THEN 'America/Los_Angeles'
      WHEN -360 THEN 'America/Chicago'
      WHEN -300 THEN 'America/New_York'
      WHEN -540 THEN 'America/Anchorage'
      WHEN -600 THEN 'Pacific/Honolulu'
      WHEN 0 THEN 'Etc/UTC'
      WHEN 60 THEN 'Europe/Paris'
      WHEN 120 THEN 'Europe/Paris'
      ELSE 'America/Los_Angeles'
    END
    """

    alter table(:children) do
      remove :utc_offset_minutes
    end
  end

  def down do
    alter table(:children) do
      add :utc_offset_minutes, :integer, null: false, default: 0
    end

    alter table(:children) do
      remove :timezone
    end
  end
end
