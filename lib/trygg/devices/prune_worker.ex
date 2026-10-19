defmodule Trygg.Devices.PruneWorker do
  @moduledoc "Oban worker that drops old device readings (see `Trygg.Devices.prune_readings/1`)."
  use Oban.Worker, queue: :cleanup, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Trygg.Devices.prune_readings()
    :ok
  end
end
