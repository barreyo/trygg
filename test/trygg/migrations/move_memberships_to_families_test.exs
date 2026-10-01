defmodule Trygg.Migrations.MoveMembershipsToFamiliesTest do
  # Rewinds the schema to its pre-family shape inside the test's transaction,
  # seeds data the way production has it, runs the real migration over it and
  # rolls everything back. DDL takes table-wide locks, so this can't share the
  # database with concurrent tests.
  use Trygg.DataCase, async: false

  @path Path.expand(
          "../../../priv/repo/migrations/20261001120000_move_memberships_to_families.exs",
          __DIR__
        )
  # Any version that isn't already in schema_migrations.
  @version 20_261_001_120_001

  defp sql!(sql, params \\ []), do: Ecto.Adapters.SQL.query!(Repo, sql, params)

  # The inverse of the migration's structural changes, on empty tables.
  defp rewind_to_legacy_schema! do
    sql!("DROP TABLE api_tokens")

    for {table, index, new_index} <- [
          {"memberships", "memberships_family_id_user_id_index",
           "memberships_child_id_user_id_index"},
          {"invites", "invites_family_id_index", "invites_child_id_index"}
        ] do
      sql!("ALTER TABLE #{table} DROP CONSTRAINT #{table}_family_id_fkey")
      sql!("ALTER TABLE #{table} RENAME COLUMN family_id TO child_id")

      sql!(
        "ALTER TABLE #{table} ADD CONSTRAINT #{table}_child_id_fkey FOREIGN KEY (child_id) REFERENCES children(id) ON DELETE CASCADE"
      )

      sql!("ALTER INDEX #{index} RENAME TO #{new_index}")
    end

    sql!("ALTER TABLE children DROP COLUMN family_id")
    sql!("DROP TABLE families")
  end

  defp seed_legacy_data! do
    sql!("""
    INSERT INTO users (id, email, first_name, last_name, inserted_at, updated_at) VALUES
      (1, 'mom@example.com', 'M', 'M', now(), now()),
      (2, 'dad@example.com', 'D', 'D', now(), now()),
      (3, 'gran@example.com', 'G', 'G', now(), now()),
      (4, 'nobody@example.com', 'N', 'N', now(), now())
    """)

    sql!("""
    INSERT INTO children (id, name, inserted_at, updated_at) VALUES
      (10, 'Alma', now(), now()), (20, 'Otto', now(), now()), (30, 'Ines', now(), now())
    """)

    # Alma: mom owner + dad caregiver. Otto: mom owner + gran viewer. Ines: dad.
    sql!("""
    INSERT INTO memberships (child_id, user_id, role, inserted_at, updated_at) VALUES
      (10, 1, 'owner', now(), now()), (10, 2, 'caregiver', now(), now()),
      (20, 1, 'owner', now(), now()), (20, 3, 'viewer', now(), now()),
      (30, 2, 'owner', now(), now())
    """)

    sql!("""
    INSERT INTO invites (child_id, invited_by_id, email, role, token, expires_at, inserted_at, updated_at)
    VALUES (20, 1, 'new@example.com', 'caregiver', 'tok', now() + interval '3 days', now(), now())
    """)

    sql!(
      "INSERT INTO log_entries (child_id, type, started_at, data, inserted_at, updated_at) VALUES (10, 'diaper', now(), '{}', now(), now())"
    )

    sql!("UPDATE users SET last_child_id = 20 WHERE id = 1")
  end

  defp migrate_up! do
    module = Trygg.Repo.Migrations.MoveMembershipsToFamilies
    unless Code.ensure_loaded?(module), do: Code.require_file(@path)

    Ecto.Migrator.run(Repo, [{@version, module}], :up,
      all: true,
      log: false,
      migration_lock: false
    )
  end

  defp rows(sql), do: sql |> sql!() |> Map.fetch!(:rows)

  test "gives every existing child a family that keeps exactly its caregivers" do
    rewind_to_legacy_schema!()
    seed_legacy_data!()

    migrate_up!()

    # One family per child, so nobody gains access to a child they couldn't see.
    assert [[10, 10], [20, 20], [30, 30]] = rows("SELECT id, family_id FROM children ORDER BY id")
    assert [[10], [20], [30]] = rows("SELECT id FROM families ORDER BY id")

    assert [
             [10, 1, "owner"],
             [10, 2, "caregiver"],
             [20, 1, "owner"],
             [20, 3, "viewer"],
             [30, 2, "owner"]
           ] =
             rows("SELECT family_id, user_id, role FROM memberships ORDER BY family_id, user_id")

    assert [[20, "new@example.com"]] = rows("SELECT family_id, email FROM invites")

    # Untouched data, and the user with no children simply has no family yet.
    assert [[1]] = rows("SELECT count(*) FROM log_entries")
    assert [[20]] = rows("SELECT last_child_id FROM users WHERE id = 1")
    assert [] = rows("SELECT 1 FROM memberships WHERE user_id = 4")
  end

  test "new families get fresh ids and the constraints follow the rename" do
    rewind_to_legacy_schema!()
    seed_legacy_data!()
    migrate_up!()

    assert [[id]] =
             rows(
               "INSERT INTO families (inserted_at, updated_at) VALUES (now(), now()) RETURNING id"
             )

    assert id > 30

    assert_raise Postgrex.Error, ~r/memberships_family_id_user_id_index/, fn ->
      sql!(
        "INSERT INTO memberships (family_id, user_id, role, inserted_at, updated_at) VALUES (10, 1, 'viewer', now(), now())"
      )
    end
  end

  test "works on a database with no children yet" do
    rewind_to_legacy_schema!()

    migrate_up!()

    assert [[0]] = rows("SELECT count(*) FROM families")

    assert [[id]] =
             rows(
               "INSERT INTO families (inserted_at, updated_at) VALUES (now(), now()) RETURNING id"
             )

    assert id == 1
  end
end
