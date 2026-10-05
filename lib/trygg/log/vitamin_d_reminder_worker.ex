defmodule Trygg.Log.VitaminDReminderWorker do
  @moduledoc """
  Oban worker that runs `Trygg.Log.VitaminDReminders.run/0`. Enqueued on a
  cron schedule (see the `Oban` config in `config/prod.exs`); unique so
  overlapping ticks collapse into one run.
  """
  use Oban.Worker,
    queue: :reminders,
    max_attempts: 3,
    unique: [period: {10, :minutes}, states: [:available, :scheduled, :executing]]

  alias Trygg.Log.VitaminDReminders

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  @impl Oban.Worker
  def perform(_job) do
    VitaminDReminders.run()
    :ok
  end
end
