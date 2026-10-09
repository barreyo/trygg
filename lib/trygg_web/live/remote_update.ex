defmodule TryggWeb.RemoteUpdate do
  @moduledoc """
  Makes a realtime update that came from somewhere else obvious.

  Several caregivers (and the button, and the API) share one child, so a screen
  can change under your thumb. When the PubSub message that triggers a refresh
  was written by another process (`Trygg.Log.Entry.remote?/1`), a LiveView
  calls `flash/2` with the things that changed; the browser then pulses them
  once (see `assets/js/remote_flash.js` and `.remote-flash` in app.css).

  Targets are CSS selectors, so this works without tracking anything in assigns
  or re-rendering stream items. Selectors that match nothing (a card the child
  doesn't track, a row that isn't loaded) are ignored by the browser.
  """
  import Phoenix.LiveView, only: [push_event: 3]

  alias Trygg.Growth.Measurement
  alias Trygg.Log.Entry

  @doc """
  Home: pulses the glance card for the entry's type and its row in the activity
  list, when the change came from elsewhere. `action` is the `{:log, action, _}`
  tag; a deleted entry has no row left to pulse.
  """
  def flash_home(socket, %Entry{} = entry, action) do
    if Entry.remote?(entry),
      do: flash(socket, [glance_card(entry.type) | entry_row(entry, action)]),
      else: socket
  end

  @doc "Timeline: pulses the entry's row, when the change came from elsewhere."
  def flash_timeline(socket, %Entry{} = entry, action) do
    if Entry.remote?(entry), do: flash(socket, entry_row(entry, action)), else: socket
  end

  @doc """
  Vitals: pulses the latest-weight / latest-height cards the measurement fed
  and its row in the table, when the change came from elsewhere.
  """
  def flash_growth(socket, %Measurement{} = m, action) do
    if Measurement.remote?(m), do: flash(socket, growth_targets(m, action)), else: socket
  end

  defp flash(socket, []), do: socket
  defp flash(socket, targets), do: push_event(socket, "remote-flash", %{targets: targets})

  defp growth_targets(m, action) do
    cards =
      [m.weight_g && "#latest-weight > *", m.height_cm && "#latest-height > *"]
      |> Enum.filter(& &1)

    row = if action == :deleted, do: [], else: ["#measurement-#{m.id}"]
    cards ++ row
  end

  defp entry_row(%Entry{id: id}, action) when action != :deleted, do: ["#entries-#{id}"]
  defp entry_row(_entry, _action), do: []

  defp glance_card(:feeding), do: "#glance-feed .glance-card"
  defp glance_card(:diaper), do: "#glance-diaper .glance-card"
  defp glance_card(:sleep), do: "#glance-sleep .glance-card"
end
