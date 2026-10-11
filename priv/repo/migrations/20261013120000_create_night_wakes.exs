defmodule Trygg.Repo.Migrations.CreateNightWakes do
  use Ecto.Migration

  def change do
    # One row per night waking worked through in night mode (C.R.I.E.S. for a
    # newborn, S.I.T. B.A.C.K. after 13 weeks). The step and when it started
    # live here, not on a device, so a partner who opens night mode picks up
    # where the other left off.
    create table(:night_wakes) do
      add :child_id, references(:children, on_delete: :delete_all), null: false
      add :started_by_id, references(:users, on_delete: :nilify_all)
      add :method, :string, null: false
      add :started_at, :utc_datetime, null: false
      add :step, :integer, null: false, default: 0
      add :step_started_at, :utc_datetime, null: false
      add :ended_at, :utc_datetime
      add :outcome, :string
      add :settled_step, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:night_wakes, [:child_id, :started_at])

    # At most one waking in progress per child.
    create unique_index(:night_wakes, [:child_id],
             where: "ended_at IS NULL",
             name: :night_wakes_one_active_per_child
           )
  end
end
