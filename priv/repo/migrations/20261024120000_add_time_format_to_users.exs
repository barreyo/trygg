defmodule Trygg.Repo.Migrations.AddTimeFormatToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :time_format, :string, null: false, default: "h24"
    end
  end
end
