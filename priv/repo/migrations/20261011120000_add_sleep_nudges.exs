defmodule Trygg.Repo.Migrations.AddSleepNudges do
  use Ecto.Migration

  def change do
    alter table(:children) do
      # Opt-in: push nudges for the nap window, a feed that may be due, and the
      # bedtime routine. Off until a caregiver turns it on in the child's settings.
      add :sleep_nudges, :boolean, null: false, default: false
    end

    # One row per nudge already sent (`key` names the moment, e.g. a wake
    # window), so overlapping scans send each at most once.
    create table(:sleep_nudge_claims) do
      add :child_id, references(:children, on_delete: :delete_all), null: false
      add :key, :string, null: false
      timestamps(updated_at: false, type: :utc_datetime)
    end

    create unique_index(:sleep_nudge_claims, [:child_id, :key])
  end
end
