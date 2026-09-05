defmodule Trygg.Growth.WeightReminderWorker do
  @moduledoc """
  Oban worker that runs `Trygg.Growth.WeightReminders.run/0`. Enqueued on a
  cron schedule (see the `Oban` config); unique so overlapping ticks collapse
  into one run.
  """
  use Oban.Worker,
    queue: :reminders,
    max_attempts: 3,
    unique: [period: {1, :hour}, states: [:available, :scheduled, :executing]]

  alias Trygg.Growth.WeightReminders

  @impl Oban.Worker
  def perform(_job) do
    WeightReminders.run()
    :ok
  end
end
