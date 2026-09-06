defmodule Trygg.Repo.Migrations.CreateSleepPredictions do
  use Ecto.Migration

  def change do
    create table(:sleep_predictions) do
      add :child_id, references(:children, on_delete: :delete_all), null: false

      # "next_nap" | "bedtime"
      add :kind, :string, null: false
      # When we made the prediction, and the wake time it keyed off.
      add :made_at, :utc_datetime, null: false
      add :made_from_ts, :utc_datetime, null: false
      # Nap number for :next_nap; null for :bedtime.
      add :ordinal, :integer
      # "history" | "blended" | "age_prior"
      add :source, :string, null: false

      add :target_ts, :utc_datetime, null: false
      add :range_lo_ts, :utc_datetime
      add :range_hi_ts, :utc_datetime

      # Filled in when the predicted sleep actually happens (or is abandoned).
      add :actual_ts, :utc_datetime
      add :error_seconds, :integer
      add :resolved_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # One open prediction per wake per kind; re-runs upsert it.
    create unique_index(:sleep_predictions, [:child_id, :kind, :made_from_ts])
    create index(:sleep_predictions, [:child_id, :kind, :resolved_at])
  end
end
