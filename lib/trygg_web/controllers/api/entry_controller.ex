defmodule TryggWeb.Api.EntryController do
  @moduledoc """
  A child's log over the REST API. Roles are the token's: reading needs a
  `viewer` token, everything else a `caregiver` one (anything else is a `403`).
  A child outside the token's family is a `404`, like one that doesn't exist.

    * `GET    /api/v1/children/:child_id/entries` — newest first; `type`,
      `since`, `until` (ISO 8601) and `limit` (default 50, at most 200)
    * `POST   /api/v1/children/:child_id/entries` — `type` (`feeding`,
      `diaper`, `sleep`), `started_at` (defaults to now), `ended_at`, `data`
      and `note`. A `sleep` with no `ended_at` starts the running timer. With a
      `client_id` (a UUID) the call is idempotent — repeating it updates the same
      entry instead of adding another — and `started_at` is required, so a
      retry can't drift the time.
    * `POST   /api/v1/children/:child_id/entries/:id/stop` — stops a running
      timer; takes `ended_at`, `data` and `note`
    * `DELETE /api/v1/children/:child_id/entries/:id`
  """
  use TryggWeb, :controller

  alias Trygg.Families
  alias Trygg.Log
  alias Trygg.Log.Entry

  action_fallback TryggWeb.Api.FallbackController

  @default_limit 50
  @max_limit 200
  @writable ~w(started_at ended_at data note client_id)

  def index(conn, %{"child_id" => child_id} = params) do
    scope = conn.assigns.current_scope
    child = Families.get_child!(scope, child_id)

    with {:ok, opts} <- list_opts(params) do
      render(conn, :index, entries: Log.list_entries(scope, child, opts))
    end
  end

  def create(conn, %{"child_id" => child_id} = params) do
    scope = conn.assigns.current_scope
    child = Families.get_child!(scope, child_id)
    attrs = params |> Map.take(@writable) |> drop_blank("ended_at")

    with {:ok, type} <- fetch_type(params),
         {:ok, entry} <- record(scope, child, type, attrs) do
      conn
      |> put_status(:created)
      |> render(:show, entry: entry)
    end
  end

  def stop(conn, %{"child_id" => child_id, "id" => id} = params) do
    scope = conn.assigns.current_scope
    child = Families.get_child!(scope, child_id)
    entry = Log.get_child_entry!(scope, child, id)

    if Entry.running?(entry) do
      with {:ok, entry} <- Log.stop_timer(scope, entry, Map.take(params, ~w(ended_at data note))) do
        render(conn, :show, entry: entry)
      end
    else
      {:error, :not_running}
    end
  end

  def delete(conn, %{"child_id" => child_id, "id" => id}) do
    scope = conn.assigns.current_scope
    child = Families.get_child!(scope, child_id)
    entry = Log.get_child_entry!(scope, child, id)

    with {:ok, _entry} <- Log.delete_entry(scope, entry) do
      send_resp(conn, :no_content, "")
    end
  end

  defp drop_blank(attrs, key) do
    if attrs[key] in [nil, ""], do: Map.delete(attrs, key), else: attrs
  end

  # Idempotent when the caller supplies a `client_id`.
  defp record(scope, child, type, %{"client_id" => _} = attrs) do
    case Log.sync_entry(scope, child, Map.put(attrs, "type", to_string(type))) do
      {:error, :missing_client_id} -> {:error, %{client_id: ["is not a valid UUID"]}}
      result -> result
    end
  end

  # A sleep with no end is the running timer, and there's at most one of those.
  defp record(scope, child, :sleep, attrs) when not is_map_key(attrs, "ended_at"),
    do: Log.start_timer(scope, child, :sleep, attrs)

  defp record(scope, child, type, attrs), do: Log.create_entry(scope, child, type, attrs)

  defp fetch_type(%{"type" => type}) when is_binary(type) do
    case Enum.find(Entry.types(), &(Atom.to_string(&1) == type)) do
      nil -> {:error, %{type: ["is invalid"]}}
      type -> {:ok, type}
    end
  end

  defp fetch_type(_params), do: {:error, %{type: ["can't be blank"]}}

  defp list_opts(params) do
    with {:ok, type} <- list_type(params["type"]),
         {:ok, since} <- parse_datetime(params, "since"),
         {:ok, until} <- parse_datetime(params, "until"),
         {:ok, limit} <- parse_limit(params["limit"]) do
      {:ok, [type: type, since: since, until: until, limit: limit]}
    end
  end

  defp list_type(nil), do: {:ok, nil}
  defp list_type(type), do: fetch_type(%{"type" => type})

  defp parse_datetime(params, key) do
    case params[key] do
      nil ->
        {:ok, nil}

      value ->
        case DateTime.from_iso8601(to_string(value)) do
          {:ok, datetime, _offset} -> {:ok, datetime}
          _ -> {:error, %{String.to_existing_atom(key) => ["must be an ISO 8601 datetime"]}}
        end
    end
  end

  defp parse_limit(nil), do: {:ok, @default_limit}

  defp parse_limit(value) do
    case Integer.parse(to_string(value)) do
      {int, ""} when int > 0 -> {:ok, min(int, @max_limit)}
      _ -> {:error, %{limit: ["must be a positive integer"]}}
    end
  end
end
