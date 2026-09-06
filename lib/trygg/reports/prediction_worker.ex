defmodule Trygg.Reports.PredictionWorker do
  @moduledoc """
  Oban worker that keeps the sleep-prediction ledger current.

  Enqueued from `Trygg.Log` with a `child_id` whenever a sleep entry is written
  (records the fresh prediction, reconciles matured ones), and on an Oban cron
  schedule with no args as a backstop that sweeps every recently-active child
  in case a broadcast-triggered job was missed.

  `unique` collapses the burst of jobs a rapid sequence of sleep edits would
  otherwise create for one child.
  """
  use Oban.Worker,
    queue: :reminders,
    max_attempts: 3,
    unique: [period: 60, keys: [:child_id], states: [:available, :scheduled, :executing]]

  alias Trygg.Reports.PredictionLedger

  # A single child's rebuild is a handful of queries plus pure computation;
  # the sweep is that per recently-active child. Bound both.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"child_id" => child_id}}) when is_integer(child_id) do
    PredictionLedger.track(child_id)
    :ok
  end

  def perform(%Oban.Job{}) do
    PredictionLedger.sweep()
    :ok
  end
end
