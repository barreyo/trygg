defmodule TryggWeb.UndoDelete do
  @moduledoc """
  A short window to take a delete back.

  Deleting a log entry or a measurement is a routine fix for a mis-tap, not a
  decision worth a browser `confirm()` dialog. Instead the row is deleted
  straight away and the screen offers "Undo" (`TryggWeb.CoreComponents.undo_toast/1`)
  for `window_ms/0`.

  A LiveView calls `stash/2` with the deleted record, renders `@undo` in the
  toast, and handles two messages: the `"undo_delete"` event (`take/1`, then
  restore the record) and `{:undo_expired, ref}` (`expire/2`).
  """
  import Phoenix.Component, only: [assign: 3]

  @window_ms 7_000

  def window_ms, do: @window_ms

  @doc "Offers to undo the deletion of `record`, replacing any earlier offer."
  def stash(socket, record) do
    ref = System.unique_integer([:positive])

    if Phoenix.LiveView.connected?(socket),
      do: Process.send_after(self(), {:undo_expired, ref}, @window_ms)

    assign(socket, :undo, %{ref: ref, record: record})
  end

  @doc "Takes the stashed record for restoring, clearing the offer: `{record | nil, socket}`."
  def take(%{assigns: %{undo: %{record: record}}} = socket),
    do: {record, assign(socket, :undo, nil)}

  def take(socket), do: {nil, socket}

  @doc """
  Restores `record` with `fun` (e.g. `&Log.restore_entry(scope, &1)`) and says
  how it went. A `nil` record (the offer already lapsed) does nothing.
  """
  def restore(socket, nil, _fun), do: socket

  def restore(socket, record, fun) do
    case fun.(record) do
      {:ok, _} ->
        Phoenix.LiveView.put_flash(socket, :info, "Restored.")

      {:error, :already_running} ->
        Phoenix.LiveView.put_flash(
          socket,
          :error,
          "Can't undo: a timer of that kind is running now."
        )

      {:error, _} ->
        Phoenix.LiveView.put_flash(socket, :error, "Couldn't undo that.")
    end
  end

  @doc "Drops the offer once its window has passed (and only if it is still the current one)."
  def expire(%{assigns: %{undo: %{ref: ref}}} = socket, ref), do: assign(socket, :undo, nil)
  def expire(socket, _ref), do: socket
end
