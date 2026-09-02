defmodule Trygg.Repo.Migrations.CreateLogEntries do
  use Ecto.Migration

  def change do
    create table(:log_entries) do
      add :child_id, references(:children, on_delete: :delete_all), null: false
      add :logged_by_id, references(:users, on_delete: :nilify_all)
      add :type, :string, null: false
      add :started_at, :utc_datetime, null: false
      add :ended_at, :utc_datetime
      add :data, :map, null: false, default: %{}
      add :note, :string

      timestamps(type: :utc_datetime)
    end

    create index(:log_entries, [:child_id, :started_at])

    create index(:log_entries, [:child_id, :type],
             where: "ended_at IS NULL",
             name: :log_entries_running_timers_index
           )
  end
end
