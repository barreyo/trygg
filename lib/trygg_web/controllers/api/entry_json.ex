defmodule TryggWeb.Api.EntryJSON do
  alias Trygg.Log.Entry

  def index(%{entries: entries}), do: %{data: Enum.map(entries, &data/1)}

  def show(%{entry: entry}), do: %{data: data(entry)}

  @doc false
  def data(%Entry{} = entry) do
    %{
      id: entry.id,
      child_id: entry.child_id,
      type: entry.type,
      started_at: entry.started_at,
      ended_at: entry.ended_at,
      running: Entry.running?(entry),
      data: entry.data,
      note: entry.note,
      client_id: entry.client_id,
      # The integration that logged it, or nil when a person did.
      logged_via: entry.logged_via,
      inserted_at: entry.inserted_at
    }
  end
end
