defmodule Trygg.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  def change do
    create table(:api_tokens) do
      add :family_id, references(:families, on_delete: :delete_all), null: false
      add :created_by_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      # The most this token may do: `viewer` (read only) or `caregiver`.
      add :role, :string, null: false
      # SHA-256 of the secret. The secret itself is shown once and never stored.
      add :token_hash, :binary, null: false
      # Last few characters of the secret, so people can tell tokens apart.
      add :hint, :string, null: false
      add :last_used_at, :utc_datetime
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:api_tokens, [:token_hash])
    create index(:api_tokens, [:family_id])
    create index(:api_tokens, [:created_by_id])
  end
end
