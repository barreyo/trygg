defmodule Trygg.Repo.Migrations.MoveMembershipsToFamilies do
  use Ecto.Migration

  # Introduces `families`: the group of caregivers that shares one or more
  # children. Memberships and invites move from the child to the family, so a
  # caregiver sees every child in it.
  #
  # Every existing child becomes its own one-child family that keeps exactly
  # its current caregivers and pending invites — nobody gains or loses access.
  # (Grouping siblings into one family afterwards is a product decision; merging
  # unrelated children here would expose them to caregivers that were never
  # invited.) The family reuses the child's id so the backfill is plain SQL.
  def up do
    create table(:families) do
      timestamps(type: :utc_datetime)
    end

    execute "INSERT INTO families (id, inserted_at, updated_at) SELECT id, now(), now() FROM children"

    execute """
    SELECT setval(
      pg_get_serial_sequence('families', 'id'),
      COALESCE((SELECT MAX(id) FROM families), 1),
      (SELECT COUNT(*) > 0 FROM families)
    )
    """

    alter table(:children) do
      add :family_id, references(:families, on_delete: :delete_all)
    end

    execute "UPDATE children SET family_id = id"
    execute "ALTER TABLE children ALTER COLUMN family_id SET NOT NULL"
    create index(:children, [:family_id])

    repoint(:memberships, "memberships_child_id_user_id_index", [:family_id, :user_id],
      unique: true
    )

    repoint(:invites, "invites_child_id_index", [:family_id])
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "moving memberships to families can't be reversed: a family may hold several children"
  end

  # `child_id` held the child's id, which is the family's id after the backfill
  # above, so only the column name, foreign key and index need to follow.
  defp repoint(table, old_index, columns, opts \\ []) do
    drop constraint(table, "#{table}_child_id_fkey")
    execute "DROP INDEX #{old_index}"
    rename table(table), :child_id, to: :family_id

    execute """
    ALTER TABLE #{table}
      ADD CONSTRAINT #{table}_family_id_fkey
      FOREIGN KEY (family_id) REFERENCES families(id) ON DELETE CASCADE
    """

    create index(table, columns, opts)
  end
end
