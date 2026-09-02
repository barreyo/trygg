defmodule Trygg.Repo.Migrations.AddUnitSystemToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :unit_system, :string, null: false, default: "metric"
    end
  end
end
