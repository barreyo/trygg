defmodule Trygg.Repo.Migrations.DefaultChildrenToPacific do
  use Ecto.Migration

  def up do
    alter table(:children) do
      modify :utc_offset_minutes, :integer, null: false, default: -480
    end
  end

  def down do
    alter table(:children) do
      modify :utc_offset_minutes, :integer, null: false, default: 0
    end
  end
end
