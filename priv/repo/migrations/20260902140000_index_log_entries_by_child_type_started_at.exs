defmodule Trygg.Repo.Migrations.IndexLogEntriesByChildTypeStartedAt do
  use Ecto.Migration

  def change do
    create index(:log_entries, [:child_id, :type, :started_at])
  end
end
