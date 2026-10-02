defmodule Trygg.Repo.Migrations.AddLoggedViaToLogEntries do
  use Ecto.Migration

  def change do
    alter table(:log_entries) do
      # Set (to the API token's name at the time) when an integration logged the
      # entry rather than a person. A snapshot, not a reference, so it survives
      # the token being renamed or revoked.
      add :logged_via, :string
    end
  end
end
