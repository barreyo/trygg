defmodule Trygg.Growth.WeightReminderWorker do
  @moduledoc """
  Oban worker that runs `Trygg.Growth.WeightReminders.run/0`. Enqueued on a
  cron schedule (see the `Oban` config); unique so overlapping ticks collapse
  into one run.

  `WeightReminders.run/0` is idempotent — it records every send in
  `growth_reminder_notifications` before moving on — so a retry after a
  mid-scan crash only re-sends to caregivers it hadn't reached yet.
  """
  use Oban.Worker,
    queue: :reminders,
    max_attempts: 3,
    unique: [period: {1, :hour}, states: [:available, :scheduled, :executing]]

  alias Trygg.Growth.WeightReminders

  # The scan is a handful of queries plus one email/push per overdue caregiver;
  # anything past a few minutes means something is wedged. Bound it so a stuck
  # run fails (and retries) instead of occupying the queue until Lifeline.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(_job) do
    WeightReminders.run()
    :ok
  end
end
