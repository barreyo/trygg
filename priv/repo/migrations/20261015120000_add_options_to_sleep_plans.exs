defmodule Trygg.Repo.Migrations.AddOptionsToSleepPlans do
  use Ecto.Migration

  def change do
    alter table(:sleep_plans) do
      # Choices that belong to the plan's method: a SWAP's variant, a SLIP's
      # check-in mode ("graduated" or "full"), and where a gradual plan started.
      add :options, :map, null: false, default: %{}
    end
  end
end
