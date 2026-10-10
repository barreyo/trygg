defmodule TryggWeb.LogSyncController do
  @moduledoc """
  Batch-syncs log entries that were captured while the PWA was offline.

  A plain JSON controller rather than a LiveView event: the offline capture
  path writes entries to IndexedDB with no live socket, then POSTs the queue
  here once the device is back online. Same session auth as the LiveViews
  (`:require_authenticated_user`).

  Every entry carries a client-generated `client_id` (a UUID), so re-POSTing a
  batch is idempotent — see `Trygg.Log.sync_entry/3`.
  """
  use TryggWeb, :controller

  alias Trygg.Families
  alias Trygg.Log

  # A generous ceiling on one flush; a real queue holds a handful of entries.
  @max_entries 200

  @doc """
  `POST /c/:id/log/entries` — body `{"entries": [{client_id, type, started_at,
  ended_at, data, note}, ...]}`.

  Always `200` with a per-entry `results` list: the caller deletes the rows
  that came back `"ok"` and stops retrying the `"rejected"` ones. A dead
  session redirects to log-in and a non-member child 404s — in both cases the
  caller keeps the whole queue.
  """
  def create(conn, %{"id" => child_id, "entries" => entries}) when is_list(entries) do
    scope = conn.assigns.current_scope
    child = Families.get_child!(scope, child_id)

    results =
      entries
      |> Enum.take(@max_entries)
      |> Enum.map(&sync_one(scope, child, &1))

    json(conn, %{results: results})
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: ~s(expected an "entries" list)})
  end

  # A "stop this running timer" row (offline Stop of a sleep that was started
  # online): keyed by the timer's server id, not a client_id.
  defp sync_one(scope, child, %{"server_id" => server_id} = attrs)
       when is_integer(server_id) or is_binary(server_id) do
    client_id = attrs["client_id"]

    case Log.sync_stop_timer(scope, child, server_id, attrs["ended_at"], attrs["data"] || %{}) do
      {:ok, entry} -> %{client_id: client_id, status: "ok", id: entry.id}
      {:error, :not_found} -> rejected(client_id, %{server_id: ["not found"]})
      {:error, %Ecto.Changeset{} = changeset} -> rejected(client_id, changeset_errors(changeset))
    end
  end

  defp sync_one(scope, child, %{"client_id" => client_id} = attrs) when is_binary(client_id) do
    case Log.sync_entry(scope, child, attrs) do
      {:ok, entry} ->
        %{client_id: entry.client_id || client_id, status: "ok", id: entry.id}

      {:error, :missing_client_id} ->
        rejected(client_id, %{client_id: ["is missing or malformed"]})

      {:error, %Ecto.Changeset{} = changeset} ->
        rejected(client_id, changeset_errors(changeset))
    end
  end

  defp sync_one(_scope, _child, _attrs) do
    rejected(nil, %{client_id: ["is missing or malformed"]})
  end

  defp rejected(client_id, errors) do
    %{client_id: client_id, status: "rejected", errors: errors}
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
