defmodule Trygg.Log.PhotoCleanupWorker do
  @moduledoc """
  Oban worker that deletes the photo of an entry that was deleted with an undo
  window (`Trygg.Log.delete_entry/3` with `undoable: true`). Enqueued to run
  after the window; if the entry was restored in the meantime something still
  references the photo and it is left alone.
  """
  use Oban.Worker, queue: :cleanup, max_attempts: 3

  alias Trygg.Log

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"key" => key}}) do
    Log.discard_unreferenced_photo(key)
    :ok
  end
end
