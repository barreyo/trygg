defmodule Trygg.Repo.Migrations.CreateFamilies do
  use Ecto.Migration

  def change do
    create table(:children) do
      add :name, :string, null: false
      add :birth_date, :date
      add :birth_time, :time
      add :sex, :string, null: false, default: "unspecified"
      # Fixed offset from UTC in minutes (e.g. -420 for US Pacific). Used to
      # decide what counts as "today" without an IANA time-zone database.
      add :utc_offset_minutes, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create table(:memberships) do
      add :child_id, references(:children, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "caregiver"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:memberships, [:child_id, :user_id])
    create index(:memberships, [:user_id])

    create table(:invites) do
      add :child_id, references(:children, on_delete: :delete_all), null: false
      add :invited_by_id, references(:users, on_delete: :nilify_all)
      add :email, :string, null: false
      add :role, :string, null: false, default: "caregiver"
      add :token, :string, null: false
      add :accepted_at, :utc_datetime
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invites, [:token])
    create index(:invites, [:child_id])
    create index(:invites, [:email])
  end
end
