defmodule Trygg.Repo.Migrations.CreatePushSubscriptions do
  use Ecto.Migration

  def change do
    create table(:push_subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :endpoint, :text, null: false
      add :p256dh, :text, null: false
      add :auth, :text, null: false
      add :user_agent, :text

      timestamps(type: :utc_datetime)
    end

    # One row per browser push endpoint; re-subscribing the same device
    # updates the existing row rather than piling up duplicates.
    create unique_index(:push_subscriptions, [:endpoint])
    create index(:push_subscriptions, [:user_id])
  end
end
