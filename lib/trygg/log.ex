defmodule Trygg.Log do
  @moduledoc """
  The shared event log for a child — bottle feeds, diapers, and sleep — plus the
  running-timer helpers and the realtime broadcasts that keep every caregiver's
  screen in sync.

  Reads require the `:viewer` role for the child; writes require `:caregiver`.
  All writes broadcast `{:log, :created | :updated | :deleted, entry}` on the
  child's `Trygg.Families` topic.
  """

  import Ecto.Query, warn: false

  alias Trygg.Repo
  alias Trygg.Accounts.Scope
  alias Trygg.Families
  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias Trygg.Storage

  require Logger

  @timer_types Entry.timer_types()

  # Cap uploaded photos at 15 MB — comfortably above a phone camera JPEG,
  # well below anything that would strain the LiveView channel.
  @max_photo_bytes 15 * 1024 * 1024

  ## Reads ------------------------------------------------------------------

  @doc """
  Lists a child's entries, newest first.

  Options: `:type` (atom), `:since` (`DateTime`), `:until` (`DateTime`),
  `:limit` (integer).
  """
  def list_entries(%Scope{} = scope, %Child{} = child, opts \\ []) do
    Families.authorize!(scope, child, :viewer)

    Entry
    |> where(child_id: ^child.id)
    |> filter_type(opts[:type])
    |> filter_since(opts[:since])
    |> filter_until(opts[:until])
    |> order_by(desc: :started_at, desc: :id)
    |> maybe_limit(opts[:limit])
    |> preload(:logged_by)
    |> Repo.all()
  end

  @doc "The most recent `limit` entries for a child."
  def recent_entries(%Scope{} = scope, %Child{} = child, limit \\ 15) do
    list_entries(scope, child, limit: limit)
  end

  @doc "The earliest `started_at` on the child's log, or `nil` when it's empty."
  def oldest_started_at(%Scope{} = scope, %Child{} = child) do
    Families.authorize!(scope, child, :viewer)

    Entry
    |> where(child_id: ^child.id)
    |> select([e], min(e.started_at))
    |> Repo.one()
  end

  @doc "Fetches one entry, authorizing the caller as a viewer of its child."
  def get_entry!(%Scope{} = scope, id) do
    entry = Entry |> Repo.get!(id) |> Repo.preload(:logged_by)
    Families.authorize!(scope, %Child{id: entry.child_id}, :viewer)
    entry
  end

  @doc "Currently running timers for a child (only `:sleep`), oldest first."
  def running_timers(%Scope{} = scope, %Child{} = child) do
    Families.authorize!(scope, child, :viewer)

    Entry
    |> where([e], e.child_id == ^child.id and is_nil(e.ended_at) and e.type in ^@timer_types)
    |> order_by(asc: :started_at)
    |> Repo.all()
  end

  @doc """
  A snapshot for the dashboard: the last feed/diaper/sleep, any running timers,
  and today's counts (in the child's local day).
  """
  def summary(%Scope{} = scope, %Child{} = child) do
    Families.authorize!(scope, child, :viewer)
    {day_start, day_end} = Child.day_bounds(child)

    %{
      last_feeding: last_of_type(child, :feeding),
      last_diaper: last_of_type(child, :diaper),
      last_sleep: last_of_type(child, :sleep),
      running: running_timers(scope, child),
      today: %{
        feedings: count_between(child, :feeding, day_start, day_end),
        diapers: count_between(child, :diaper, day_start, day_end),
        sleep_seconds: sleep_seconds_between(child, day_start, day_end)
      }
    }
  end

  defp last_of_type(child, type) do
    Entry
    |> where([e], e.child_id == ^child.id and e.type == ^type)
    |> order_by(desc: :started_at, desc: :id)
    |> limit(1)
    |> preload(:logged_by)
    |> Repo.one()
  end

  defp count_between(child, type, from, to) do
    Repo.one(
      from e in Entry,
        where:
          e.child_id == ^child.id and e.type == ^type and
            e.started_at >= ^from and e.started_at < ^to,
        select: count(e.id)
    )
  end

  defp sleep_seconds_between(child, from, to) do
    now = DateTime.utc_now()

    Entry
    |> where([e], e.child_id == ^child.id and e.type == :sleep and e.started_at < ^to)
    |> where([e], is_nil(e.ended_at) or e.ended_at > ^from)
    |> Repo.all()
    |> Enum.reduce(0, fn e, acc ->
      seg_start = max_dt(e.started_at, from)
      seg_end = min_dt(e.ended_at || now, to)
      acc + max(DateTime.diff(seg_end, seg_start, :second), 0)
    end)
  end

  defp max_dt(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
  defp min_dt(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  ## Writes -----------------------------------------------------------------

  @doc "Returns an `%Ecto.Changeset{}` for an entry form."
  def change_entry(%Entry{} = entry, attrs \\ %{}) do
    Entry.changeset(entry, attrs)
  end

  @doc """
  Creates an entry of `type` for the child. `attrs` may carry `"started_at"`,
  `"ended_at"`, `"note"` and a `"data"` map. Requires `:caregiver`.

  A `:feeding` entry created without an explicit `"ended_at"` is treated as
  instantaneous (`ended_at == started_at`); only `:sleep` has running timers,
  started with `start_timer/4`.
  """
  def create_entry(%Scope{} = scope, %Child{} = child, type, attrs \\ %{}) do
    Families.authorize!(scope, child, :caregiver)

    started_at = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      attrs
      |> stringify()
      |> Map.put_new("type", to_string(type))
      |> Map.put_new("started_at", started_at)

    attrs =
      if type == :feeding do
        Map.put_new(attrs, "ended_at", attrs["started_at"])
      else
        attrs
      end

    %Entry{child_id: child.id, logged_by_id: scope.user.id}
    |> Entry.changeset(attrs)
    |> Repo.insert()
    |> broadcast(child.id, :created)
  end

  @doc """
  Updates an entry. Requires `:caregiver` for the entry's child.

  When `attrs` changes `photo_key` (to a new key or to `nil`), the previously
  stored photo is deleted from `Trygg.Storage` on success.
  """
  def update_entry(%Scope{} = scope, %Entry{} = entry, attrs) do
    Families.authorize!(scope, %Child{id: entry.child_id}, :caregiver)

    old_key = entry.photo_key

    result =
      entry
      |> Entry.changeset(stringify(attrs))
      |> Repo.update()
      |> broadcast(entry.child_id, :updated)

    with {:ok, updated} <- result,
         true <- is_binary(old_key) and old_key != updated.photo_key do
      discard_photo(old_key)
    end

    result
  end

  @doc "Deletes an entry. Requires `:caregiver` for the entry's child."
  def delete_entry(%Scope{} = scope, %Entry{} = entry) do
    Families.authorize!(scope, %Child{id: entry.child_id}, :caregiver)

    result =
      entry
      |> Repo.delete()
      |> broadcast(entry.child_id, :deleted)

    with {:ok, _} <- result, do: discard_photo(entry.photo_key)

    result
  end

  ## Timers ---------------------------------------------------------------

  @doc """
  Starts a running `:sleep` timer. If one is already running it is returned
  unchanged, so tapping twice is harmless. Requires `:caregiver`.
  """
  def start_timer(%Scope{} = scope, %Child{} = child, type, attrs \\ %{})
      when type in @timer_types do
    Families.authorize!(scope, child, :caregiver)

    case running_of_type(child, type) do
      %Entry{} = running ->
        {:ok, running}

      nil ->
        attrs =
          attrs
          |> stringify()
          |> Map.put("type", to_string(type))
          |> Map.put_new("started_at", DateTime.utc_now() |> DateTime.truncate(:second))
          |> Map.delete("ended_at")

        %Entry{child_id: child.id, logged_by_id: scope.user.id}
        |> Entry.changeset(attrs)
        |> Repo.insert()
        |> broadcast(child.id, :created)
    end
  end

  @doc """
  Stops a running timer, setting `ended_at` to now and merging any extra `data`
  from `attrs` (e.g. the bottle amount measured at the end). Requires `:caregiver`.
  """
  def stop_timer(%Scope{} = scope, %Entry{} = entry, attrs \\ %{}) do
    Families.authorize!(scope, %Child{id: entry.child_id}, :caregiver)

    attrs = stringify(attrs)
    ended_at = Map.get(attrs, "ended_at", DateTime.utc_now() |> DateTime.truncate(:second))
    merged_data = Map.merge(entry.data || %{}, Map.get(attrs, "data", %{}) |> stringify())

    changes =
      %{
        "type" => to_string(entry.type),
        "started_at" => entry.started_at,
        "ended_at" => ended_at,
        "data" => merged_data,
        "note" => Map.get(attrs, "note", entry.note)
      }
      |> Map.merge(Map.take(attrs, ["photo_key", "photo_content_type"]))

    entry
    |> Entry.changeset(changes)
    |> Repo.update()
    |> broadcast(entry.child_id, :updated)
  end

  defp running_of_type(child, type) do
    Entry
    |> where([e], e.child_id == ^child.id and e.type == ^type and is_nil(e.ended_at))
    |> order_by(desc: :started_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Adjusts an entry's timing (`"started_at"` / `"ended_at"`) and/or `"note"`
  while leaving its type-specific `data` untouched. Used to nudge a running
  sleep timer's start back, correct its end, etc. Requires `:caregiver`.
  """
  def retime_entry(%Scope{} = scope, %Entry{} = entry, attrs) do
    attrs = stringify(attrs)

    update_entry(scope, entry, %{
      "type" => to_string(entry.type),
      "started_at" => Map.get(attrs, "started_at", entry.started_at),
      "ended_at" => Map.get(attrs, "ended_at", entry.ended_at),
      "data" => entry.data || %{},
      "note" => Map.get(attrs, "note", entry.note)
    })
  end

  ## Photos -----------------------------------------------------------

  @doc "The largest photo, in bytes, an entry will accept."
  def max_photo_bytes, do: @max_photo_bytes

  @doc "Accepted photo content types."
  def photo_content_types, do: Entry.photo_content_types()

  @doc "File-picker `accept` extensions matching `photo_content_types/0`."
  def photo_extensions, do: ~w(.jpg .jpeg .png .webp .gif)

  @doc """
  Stores `binary` as a photo for `child` and returns attrs to merge into a
  `create_entry/4` or `update_entry/3` call:

      {:ok, %{"photo_key" => "children/1/log/….jpg", "photo_content_type" => "image/jpeg"}}

  `{:error, :unsupported_type}` for a non-image, `{:error, :too_large}` past
  `max_photo_bytes/0`, or `{:error, reason}` if the storage write fails.
  """
  def store_photo(%Child{} = child, binary, content_type) when is_binary(binary) do
    cond do
      content_type not in photo_content_types() ->
        {:error, :unsupported_type}

      byte_size(binary) > @max_photo_bytes ->
        {:error, :too_large}

      true ->
        key = photo_key(child, content_type)

        case Storage.put(key, binary, content_type) do
          :ok -> {:ok, %{"photo_key" => key, "photo_content_type" => content_type}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Reads an entry's photo. `{:ok, binary, content_type}` or `:error` when the
  entry has no photo or the bytes can't be fetched.
  """
  def fetch_photo(%Entry{photo_key: key, photo_content_type: content_type})
      when is_binary(key) and key != "" do
    case Storage.get(key) do
      {:ok, binary} -> {:ok, binary, content_type || "application/octet-stream"}
      _ -> :error
    end
  end

  def fetch_photo(%Entry{}), do: :error

  defp photo_key(%Child{id: child_id}, content_type) do
    "children/#{child_id}/log/#{Ecto.UUID.generate()}#{photo_ext(content_type)}"
  end

  defp photo_ext("image/jpeg"), do: ".jpg"
  defp photo_ext("image/png"), do: ".png"
  defp photo_ext("image/webp"), do: ".webp"
  defp photo_ext("image/gif"), do: ".gif"
  defp photo_ext(_), do: ""

  # Best-effort: a failed cleanup shouldn't fail the surrounding write.
  defp discard_photo(key) when is_binary(key) and key != "" do
    case Storage.delete(key) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("failed to delete photo #{key}: #{inspect(reason)}")
    end
  end

  defp discard_photo(_), do: :ok

  ## Helpers ------------------------------------------------------------

  defp broadcast({:ok, entry} = ok, child_id, action) do
    Families.broadcast(child_id, {:log, action, entry})
    ok
  end

  defp broadcast(other, _child_id, _action), do: other

  defp filter_type(query, nil), do: query
  defp filter_type(query, type), do: where(query, [e], e.type == ^type)

  defp filter_since(query, nil), do: query
  defp filter_since(query, since), do: where(query, [e], e.started_at >= ^since)

  defp filter_until(query, nil), do: query
  defp filter_until(query, until), do: where(query, [e], e.started_at < ^until)

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify(_), do: %{}
end
