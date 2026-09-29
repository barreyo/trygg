defmodule Trygg.Repo.Migrations.CreateNoticeDismissals do
  use Ecto.Migration

  def change do
    create table(:notice_dismissals) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :child_id, references(:children, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :dismissed_until, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    # Re-dismissing the same notice extends the existing row.
    create unique_index(:notice_dismissals, [:user_id, :child_id, :key])
    create index(:notice_dismissals, [:child_id])
  end
end
