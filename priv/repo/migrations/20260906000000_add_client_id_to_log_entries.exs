defmodule Trygg.Repo.Migrations.AddClientIdToLogEntries do
  use Ecto.Migration

  def change do
    # A client-generated UUID for entries captured offline and synced later.
    # Nullable: entries written through the LiveView path (the common case)
    # never carry one. The partial unique index makes a re-sync of the same
    # offline entry land on the existing row instead of duplicating it.
    alter table(:log_entries) do
      add :client_id, :binary_id
    end

    create unique_index(:log_entries, [:child_id, :client_id],
             where: "client_id IS NOT NULL",
             name: :log_entries_child_id_client_id_index
           )
  end
end
