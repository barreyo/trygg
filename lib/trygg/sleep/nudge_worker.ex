defmodule Trygg.Sleep.NudgeWorker do
  @moduledoc """
  Oban worker that runs `Trygg.Sleep.Nudges.run/0`. Enqueued on a cron schedule
  (see the `Oban` config in `config/prod.exs`); unique so overlapping ticks
  collapse into one run.
  """
  use Oban.Worker,
    queue: :reminders,
    max_attempts: 3,
    unique: [period: {4, :minutes}, states: [:available, :scheduled, :executing]]

  alias Trygg.Sleep.Nudges

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  @impl Oban.Worker
  def perform(_job) do
    Nudges.run()
    :ok
  end
end
