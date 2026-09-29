defmodule Trygg.Repo.Migrations.AddGestationalAgeToChildren do
  use Ecto.Migration

  def change do
    alter table(:children) do
      # Gestational age at birth in days (e.g. 34+2 weeks = 240). `nil` means
      # unknown / full term. Used to correct growth percentiles for preterm
      # babies.
      add :gestational_age_days, :integer
    end
  end
end
