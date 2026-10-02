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

  @doc """
  Fetches one of `child`'s entries, authorizing the caller as a viewer of the
  child. Raises `Ecto.NoResultsError` for an id that isn't one of the child's
  entries, so callers can't probe for other children's.
  """
  def get_child_entry!(%Scope{} = scope, %Child{} = child, id) do
    Families.authorize!(scope, child, :viewer)
    Entry |> Repo.get_by!(id: id, child_id: child.id) |> Repo.preload(:logged_by)
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
    diaper_kinds = diaper_kinds_between(child, day_start, day_end)

    %{
      last_feeding: last_of_type(child, :feeding),
      last_diaper: last_of_type(child, :diaper),
      last_sleep: last_of_type(child, :sleep),
      running: running_timers(scope, child),
      today: %{
        feedings: count_between(child, :feeding, day_start, day_end),
        volume_ml: volume_ml_between(child, day_start, day_end),
        diapers: length(diaper_kinds),
        diapers_wet: Enum.count(diaper_kinds, &(&1 in ["pee", "mixed"])),
        diapers_dirty: Enum.count(diaper_kinds, &(&1 in ["poo", "mixed"])),
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

  defp volume_ml_between(child, from, to) do
    Repo.one(
      from e in Entry,
        where:
          e.child_id == ^child.id and e.type == :feeding and
            e.started_at >= ^from and e.started_at < ^to,
        select: sum(fragment("(?->>'amount_ml')::float", e.data))
    ) || 0.0
  end

  # Diaper `kind`s ("pee" / "poo" / "mixed") logged in the window, used to
  # split today's diaper count into wet vs. dirty (mirrors the same
  # pee/mixed and poo/mixed grouping as `Trygg.Reports.Diapers`).
  defp diaper_kinds_between(child, from, to) do
    Repo.all(
      from e in Entry,
        where:
          e.child_id == ^child.id and e.type == :diaper and
            e.started_at >= ^from and e.started_at < ^to,
        select: fragment("?->>'kind'", e.data)
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

  # Whom to credit for a new entry. A request on an API token is credited to the
  # integration, not to the caregiver who issued the token: it wasn't them.
  defp author(%Scope{api_token: %Trygg.Families.ApiToken{name: name}}),
    do: [logged_by_id: nil, logged_via: name]

  defp author(%Scope{user: user}), do: [logged_by_id: user.id]

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

    struct!(Entry, [child_id: child.id] ++ author(scope))
    |> Entry.changeset(attrs)
    |> Repo.insert()
    |> broadcast(child.id, :created)
  end

  @doc """
  Idempotently records an entry that was captured offline and is now being
  synced. `attrs` must carry a client-generated `"client_id"` (a UUID) and the
  real event time in `"started_at"`; re-syncing the same `client_id` for the
  child updates that row in place instead of inserting a duplicate.

  Like `create_entry/4` it requires `:caregiver` and broadcasts — `:created`
  the first time a `client_id` is seen for the child, `:updated` on a re-sync.

  Returns `{:error, :missing_client_id}` when the `client_id` is absent or
  malformed; otherwise `{:ok, entry}` / `{:error, %Ecto.Changeset{}}`.
  """
  def sync_entry(%Scope{} = scope, %Child{} = child, attrs) do
    Families.authorize!(scope, child, :caregiver)

    attrs = stringify(attrs)

    with {:ok, client_id} <- fetch_client_id(attrs) do
      attrs =
        attrs
        |> Map.put("client_id", client_id)
        |> clamp_started_at()
        |> instantaneous_feeding()

      result =
        case Repo.get_by(Entry, child_id: child.id, client_id: client_id) do
          nil ->
            struct!(Entry, [child_id: child.id] ++ author(scope))
            |> Entry.changeset(attrs)
            |> Repo.insert(
              on_conflict: {:replace, [:started_at, :ended_at, :data, :note, :updated_at]},
              conflict_target:
                {:unsafe_fragment, ~s<("child_id", "client_id") WHERE "client_id" IS NOT NULL>}
            )
            |> broadcast(child.id, :created)

          %Entry{} = existing ->
            existing
            |> Entry.changeset(attrs)
            |> Repo.update()
            |> broadcast(existing.child_id, :updated)
        end

      with {:ok, entry} <- result, do: {:ok, collapse_open_sleeps(entry)}
    end
  end

  @doc """
  Stops an already-persisted running timer by its server `id` — the offline
  "Stop sleep" for a sleep that was started while online, so there is no
  `client_id` to key on. `ended_at` (ISO8601) is the moment the caregiver
  tapped stop; a value far in the future is pulled back to now. Requires
  `:caregiver` for the timer's child. Idempotent.

  `{:error, :not_found}` if the entry is gone or belongs to another child.
  """
  def sync_stop_timer(%Scope{} = scope, %Child{} = child, id, ended_at) do
    with {int, ""} <- Integer.parse(to_string(id)),
         %Entry{child_id: child_id} = entry when child_id == child.id <- Repo.get(Entry, int) do
      stop_timer(scope, entry, %{"ended_at" => clamp_future(ended_at)})
    else
      _ -> {:error, :not_found}
    end
  end

  # At most one running sleep per child. When a sync leaves an open sleep and
  # the child has others open — two caregivers each started one, at least one
  # offline — treat them as the same sleep: keep the earliest start, fold any
  # note/data from the rest into it, and delete the rest.
  defp collapse_open_sleeps(%Entry{type: :sleep, ended_at: nil, child_id: child_id} = entry) do
    others =
      Entry
      |> where(
        [e],
        e.child_id == ^child_id and e.type == :sleep and is_nil(e.ended_at) and e.id != ^entry.id
      )
      |> Repo.all()

    case others do
      [] ->
        entry

      _ ->
        all = [entry | others]
        kept = Enum.min_by(all, & &1.started_at, DateTime)
        losers = Enum.reject(all, &(&1.id == kept.id))

        note = kept.note || Enum.find_value(losers, & &1.note)
        data = Enum.reduce(losers, kept.data || %{}, &Map.merge(&1.data || %{}, &2))

        {:ok, kept} =
          kept
          |> Entry.changeset(%{
            "type" => "sleep",
            "started_at" => kept.started_at,
            "note" => note,
            "data" => data
          })
          |> Repo.update()

        Enum.each(losers, fn loser ->
          {:ok, _} = Repo.delete(loser)
          Families.broadcast(child_id, {:log, :deleted, loser})
        end)

        Families.broadcast(child_id, {:log, :updated, kept})
        kept
    end
  end

  defp collapse_open_sleeps(entry), do: entry

  defp fetch_client_id(attrs) do
    case Ecto.UUID.cast(attrs["client_id"]) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :missing_client_id}
    end
  end

  # Trust the device's event time, but a clock running fast shouldn't file an
  # entry in the future. Anything more than two minutes ahead of the server
  # clock is pulled back to now; past timestamps are left alone.
  defp clamp_started_at(attrs) do
    case parse_dt(attrs["started_at"]) do
      {:ok, dt} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        dt = DateTime.truncate(dt, :second)
        Map.put(attrs, "started_at", if(DateTime.diff(dt, now) > 120, do: now, else: dt))

      :error ->
        attrs
    end
  end

  # Pull a timestamp more than two minutes ahead of the server clock back to
  # now; leave everything else (including `nil`) untouched.
  defp clamp_future(value) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case parse_dt(value) do
      {:ok, dt} ->
        dt = DateTime.truncate(dt, :second)
        if DateTime.diff(dt, now) > 120, do: now, else: dt

      :error ->
        value
    end
  end

  # Feeds are instantaneous, same as `create_entry/4` — fill in `ended_at`
  # when an offline client left it blank (absent or an explicit `null`).
  defp instantaneous_feeding(%{"type" => "feeding", "started_at" => started} = attrs) do
    case Map.get(attrs, "ended_at") do
      nil -> Map.put(attrs, "ended_at", started)
      _ -> attrs
    end
  end

  defp instantaneous_feeding(attrs), do: attrs

  defp parse_dt(%DateTime{} = dt), do: {:ok, dt}

  defp parse_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_dt(_), do: :error

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

        struct!(Entry, [child_id: child.id] ++ author(scope))
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

  @doc """
  `accept` list for the photo file picker, matching `photo_content_types/0`.

  Leading with the image MIME types (rather than only extensions) is what makes
  mobile browsers offer the camera: iOS shows its "Photo Library / Take Photo /
  Choose File" sheet and Android's picker includes the camera alongside the
  gallery. The extensions stay as a fallback for the browsers that hand us a
  bare `application/octet-stream` for a genuine JPEG.
  """
  def photo_accept, do: ~w(image/jpeg image/png image/webp image/gif .jpg .jpeg .png .webp .gif)

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
    maybe_track_predictions(entry)
    ok
  end

  defp broadcast(other, _child_id, _action), do: other

  # Every sleep write nudges the prediction ledger to record the fresh
  # nap/bedtime target and reconcile any that have now come due. Config-gated
  # (off in test); enqueue failures must never fail the log write.
  defp maybe_track_predictions(%Entry{type: :sleep, child_id: child_id}) do
    if Application.get_env(:trygg, Trygg.Reports, [])[:track_predictions] == true do
      %{child_id: child_id}
      |> Trygg.Reports.PredictionWorker.new()
      |> Oban.insert()
    end
  rescue
    error ->
      Logger.warning("prediction tracking enqueue failed: #{inspect(error)}")
      :ok
  end

  defp maybe_track_predictions(_entry), do: :ok

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
