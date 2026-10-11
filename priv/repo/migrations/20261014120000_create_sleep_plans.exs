defmodule Trygg.Repo.Migrations.CreateSleepPlans do
  use Ecto.Migration

  def change do
    # A sleep-training plan being followed (today: "The ABCs of Sleep", 14
    # nights). `started_on` is the evening of night 1.
    create table(:sleep_plans) do
      add :child_id, references(:children, on_delete: :delete_all), null: false
      add :started_by_id, references(:users, on_delete: :nilify_all)
      add :definition, :string, null: false
      add :status, :string, null: false, default: "active"
      add :started_on, :date, null: false
      add :ended_on, :date
      # How night feeds are weaned: "breast" or "bottle", the times (minutes
      # after midnight, evening first) and the starting amounts (minutes or ml).
      add :feed_kind, :string
      add :feed_times, {:array, :integer}, null: false, default: []
      add :feed_amounts, {:array, :integer}, null: false, default: []
      add :notes, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:sleep_plans, [:child_id, :started_on])

    create unique_index(:sleep_plans, [:child_id],
             where: "status = 'active'",
             name: :sleep_plans_one_active_per_child
           )

    alter table(:night_wakes) do
      add :plan_id, references(:sleep_plans, on_delete: :nilify_all)
      # "waking", or "bedtime" for the put-down at the start of the night.
      add :kind, :string, null: false, default: "waking"
      # Timestamped happenings in a check-in waking: cry, pop_in, calm, asleep.
      add :events, {:array, :map}, null: false, default: []
      add :cry_seconds, :integer
    end

    create index(:night_wakes, [:plan_id])
  end
end
