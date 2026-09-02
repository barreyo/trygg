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

  schema "log_entries" do
    field :type, Ecto.Enum, values: @types
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :data, :map, default: %{}
    field :note, :string

    belongs_to :child, Trygg.Families.Child
    belongs_to :logged_by, Trygg.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:type, :started_at, :ended_at, :note])
    |> validate_required([:type, :started_at])
    |> validate_end_after_start()
    |> put_data(attrs)
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
        "amount_ml" => amount
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

  @doc "Duration in seconds between start and end (or now, if still running)."
  def duration_seconds(%__MODULE__{started_at: start, ended_at: nil}) do
    DateTime.diff(DateTime.utc_now(), start, :second)
  end

  def duration_seconds(%__MODULE__{started_at: start, ended_at: ended}) do
    DateTime.diff(ended, start, :second)
  end

  def types, do: @types
  def timer_types, do: @timer_types
  def sleep_locations, do: @sleep_locations
  def bottle_contents, do: @bottle_contents
  def diaper_kinds, do: @diaper_kinds
end
