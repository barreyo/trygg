defmodule Trygg.Repo.Migrations.AddExpectedBirthDateToChildren do
  use Ecto.Migration

  def change do
    alter table(:children) do
      # The expected delivery date while a child is still "expecting". Once the
      # baby arrives a caregiver confirms `birth_date` and this is cleared.
      add :expected_birth_date, :date
    end
  end
end
