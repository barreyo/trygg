defmodule Trygg.Repo.Migrations.AddPhotoToLogEntries do
  use Ecto.Migration

  def change do
    alter table(:log_entries) do
      add :photo_key, :string
      add :photo_content_type, :string
    end
  end
end
