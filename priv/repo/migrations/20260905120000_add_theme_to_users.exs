defmodule Trygg.Repo.Migrations.AddThemeToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :theme, :string, null: false, default: "system"
    end
  end
end
