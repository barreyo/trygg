defmodule Trygg.Push.DeliveryWorker do
  @moduledoc """
  Delivers one Web Push message to one subscription.

  `Trygg.Push.enqueue/2` fans an app event out into one job per device so a
  single dead or slow endpoint retries — or is pruned — on its own, without
  blocking the others or re-sending to the ones that already succeeded. A Web
  Push POST isn't idempotent, so the unit of retry is a single subscription
  rather than the whole fan-out.
  """
  use Oban.Worker, queue: :push, max_attempts: 5

  alias Trygg.Push

  # A single encrypted POST to a push service. 30s is well past a healthy
  # response; beyond that, fail and let the backoff retry.
  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_id" => id, "payload" => payload}}) do
    Push.deliver_one(id, payload)
  end
end
