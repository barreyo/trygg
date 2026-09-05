defmodule Trygg.Repo.Migrations.AddLastChildIdToUsers do
  use Ecto.Migration

  # The child this caregiver was last looking at. `/` (the PWA start_url and the
  # target of every post-logout / not-found / "no :id" redirect) reopens this
  # child instead of jumping to whichever child was added most recently.
  # Nilified if that child is deleted; falls back to the newest child.
  def change do
    alter table(:users) do
      add :last_child_id, references(:children, on_delete: :nilify_all)
    end

    create index(:users, [:last_child_id])
  end
end
