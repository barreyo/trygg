defmodule Trygg.Repo.Migrations.AddNameToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :first_name, :string
      add :last_name, :string
    end

    # Backfill existing rows from the email local-part so the columns can be
    # made non-null. Every new user supplies a real name at registration.
    execute """
    UPDATE users
    SET first_name = initcap(COALESCE(NULLIF(split_part(email, '@', 1), ''), 'Caregiver')),
        last_name = ''
    WHERE first_name IS NULL
    """

    alter table(:users) do
      modify :first_name, :string, null: false
      modify :last_name, :string, null: false
    end
  end

  def down do
    alter table(:users) do
      remove :first_name
      remove :last_name
    end
  end
end
