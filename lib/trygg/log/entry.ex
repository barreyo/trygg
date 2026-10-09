defmodule Trygg.Log.Entry do
  @moduledoc """
  A single logged event for a child: a bottle feed, a diaper, or a stretch of
  sleep.

  Type-specific fields live in the free-form `data` map (string keys) and are
  whitelisted/validated per `type` by `changeset/2`. `ended_at` being `nil` on a
  `:sleep` entry means the timer is still running. Feeds and diapers are
  instantaneous (`ended_at == started_at`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @types [:feeding, :diaper, :sleep]
  @timer_types [:sleep]

  @bottle_contents ~w(formula expressed donor)
  @diaper_kinds ~w(pee poo mixed)
  @sleep_locations ~w(bassinet crib contact stroller other)
  @photo_content_types ~w(image/jpeg image/png image/webp image/gif)

  schema "log_entries" do
    field :type, Ecto.Enum, values: @types
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :data, :map, default: %{}
    field :note, :string

    # An optional photo attached to the entry, stored via `Trygg.Storage`.
    # `photo_key` is the storage key; `nil` means no photo.
    field :photo_key, :string
    field :photo_content_type, :string

    # A client-generated UUID for entries captured offline (see
    # `Trygg.Log.sync_entry/3`). `nil` for entries written online through the
    # LiveView path. Unique per child, so a re-sync updates in place.
    field :client_id, Ecto.UUID

    belongs_to :child, Trygg.Families.Child
    # Who logged it: a caregiver (`logged_by`), or an integration using a family
    # API token, in which case `logged_by` is nil and `logged_via` names the
    # token. See `logged_by_integration?/1`.
    belongs_to :logged_by, Trygg.Accounts.User
    field :logged_via, :string

    # Stamped onto the copy of the entry that is broadcast, with the pid of the
    # process that wrote it. Never persisted. See `remote?/1`.
    field :origin, :any, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :type,
      :started_at,
      :ended_at,
      :note,
      :photo_key,
      :photo_content_type,
      :client_id
    ])
    |> validate_required([:type, :started_at])
    |> validate_end_after_start()
    |> validate_photo()
    |> put_data(attrs)
  end

  # A photo is all-or-nothing: keep both columns or neither, and only accept
  # content types we can actually render in the feed.
  defp validate_photo(changeset) do
    case get_field(changeset, :photo_key) do
      nil ->
        put_change(changeset, :photo_content_type, nil)

      "" ->
        changeset |> put_change(:photo_key, nil) |> put_change(:photo_content_type, nil)

      _key ->
        changeset
        |> validate_required([:photo_content_type])
        |> validate_inclusion(:photo_content_type, @photo_content_types,
          message: "isn't a supported image type"
        )
    end
  end

  defp validate_end_after_start(changeset) do
    started = get_field(changeset, :started_at)
    ended = get_field(changeset, :ended_at)

    if started && ended && DateTime.compare(ended, started) == :lt do
      add_error(changeset, :ended_at, "must be after the start time")
    else
      changeset
    end
  end

  defp put_data(changeset, attrs) do
    raw = Map.get(attrs, "data", Map.get(attrs, :data, %{})) || %{}
    raw = normalize_keys(raw)

    case get_field(changeset, :type) do
      nil -> changeset
      type -> validate_type_data(changeset, type, raw)
    end
  end

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp normalize_keys(_), do: %{}

  # feeding (bottle only) -------------------------------------------------
  defp validate_type_data(changeset, :feeding, raw) do
    amount = number(raw["amount_ml"])

    data =
      drop_nils(%{
        "bottle_contents" => enum(raw["bottle_contents"], @bottle_contents),
        "amount_ml" => amount,
        # Only ever stored as `true`: a missing key means no drop was given.
        "vitamin_d" => if(truthy?(raw["vitamin_d"]), do: true)
      })

    cond do
      not is_number(amount) ->
        add_error(changeset, :data, "a feed needs an amount")

      amount < 0 ->
        add_error(changeset, :data, "amount can't be negative")

      true ->
        put_change(changeset, :data, data)
    end
  end

  # diaper ----------------------------------------------------------------
  defp validate_type_data(changeset, :diaper, raw) do
    kind = enum(raw["kind"], @diaper_kinds)

    if kind do
      data =
        drop_nils(%{
          "kind" => kind,
          "color" => blank_to_nil(raw["color"]),
          "consistency" => blank_to_nil(raw["consistency"])
        })

      put_change(changeset, :data, data)
    else
      add_error(changeset, :data, "diaper kind must be pee, poo or mixed")
    end
  end

  # sleep ---------------------------------------------------------------
  defp validate_type_data(changeset, :sleep, raw) do
    data = drop_nils(%{"location" => enum(raw["location"], @sleep_locations)})
    put_change(changeset, :data, data)
  end

  defp truthy?(value), do: value in [true, "true", "on", "1", 1]

  defp enum(value, allowed) do
    v = blank_to_nil(value)
    if v in allowed, do: v, else: nil
  end

  defp number(nil), do: nil
  defp number(n) when is_number(n), do: n * 1.0

  defp number(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp number(_), do: nil

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(s) when is_binary(s),
    do: if(String.trim(s) == "", do: nil, else: String.trim(s))

  defp blank_to_nil(other), do: other

  defp drop_nils(map), do: for({k, v} <- map, not is_nil(v), into: %{}, do: {k, v})

  @doc "Whether this entry is an unfinished timer."
  def running?(%__MODULE__{type: type, ended_at: nil}) when type in @timer_types, do: true
  def running?(%__MODULE__{}), do: false

  @doc "Whether a vitamin D drop was given with this feed."
  def vitamin_d?(%__MODULE__{type: :feeding, data: %{"vitamin_d" => true}}), do: true
  def vitamin_d?(%__MODULE__{}), do: false

  @doc "Whether this entry has a photo attached."
  def has_photo?(%__MODULE__{photo_key: key}) when is_binary(key) and key != "", do: true
  def has_photo?(%__MODULE__{}), do: false

  @doc "Duration in seconds between start and end (or now, if still running)."
  def duration_seconds(%__MODULE__{started_at: start, ended_at: nil}) do
    DateTime.diff(DateTime.utc_now(), start, :second)
  end

  def duration_seconds(%__MODULE__{started_at: start, ended_at: ended}) do
    DateTime.diff(ended, start, :second)
  end

  def types, do: @types

  @doc "Whether an integration (an API token) logged the entry, rather than a person."
  def logged_by_integration?(%__MODULE__{logged_via: via}), do: is_binary(via)

  @doc """
  Whether this broadcast entry was written by a different process than the
  caller — another device, another caregiver, an API token or the button —
  rather than by the caller's own LiveView. A LiveView uses it to tell "my tap
  just landed" from "someone else changed something". `false` for an entry that
  didn't arrive by broadcast.
  """
  def remote?(%__MODULE__{origin: origin}), do: is_pid(origin) and origin != self()

  def timer_types, do: @timer_types
  def sleep_locations, do: @sleep_locations
  def bottle_contents, do: @bottle_contents
  def diaper_kinds, do: @diaper_kinds
  def photo_content_types, do: @photo_content_types
end
