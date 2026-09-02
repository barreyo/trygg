defmodule Trygg.Growth.Measurement do
  @moduledoc """
  A height and/or weight reading for a child, taken on a calendar date.

  Values are stored in canonical metric units (`weight_g`, `height_cm`). At
  least one of the two must be present. `measured_at` is the child's local
  midnight for that date, stored in UTC.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "growth_measurements" do
    field :measured_at, :utc_datetime
    field :weight_g, :float
    field :height_cm, :float
    field :note, :string

    belongs_to :child, Trygg.Families.Child
    belongs_to :logged_by, Trygg.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(measurement, attrs) do
    measurement
    |> cast(attrs, [:measured_at, :weight_g, :height_cm, :note])
    |> update_change(:note, &blank_to_nil/1)
    |> validate_required([:measured_at])
    |> validate_number(:weight_g, greater_than: 0, less_than_or_equal_to: 100_000)
    |> validate_number(:height_cm, greater_than: 0, less_than_or_equal_to: 200)
    |> validate_length(:note, max: 200)
    |> validate_at_least_one_metric()
    |> validate_not_future()
    |> unique_constraint([:child_id, :measured_at],
      message: "already a measurement on this date"
    )
  end

  defp validate_at_least_one_metric(changeset) do
    weight = get_field(changeset, :weight_g)
    height = get_field(changeset, :height_cm)

    if is_nil(weight) and is_nil(height) do
      add_error(changeset, :weight_g, "enter a weight or a height")
    else
      changeset
    end
  end

  defp validate_not_future(changeset) do
    case get_field(changeset, :measured_at) do
      %DateTime{} = dt ->
        if DateTime.compare(dt, DateTime.utc_now()) == :gt do
          add_error(changeset, :measured_at, "can't be in the future")
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(s) when is_binary(s),
    do: if(String.trim(s) == "", do: nil, else: String.trim(s))

  defp blank_to_nil(other), do: other
end
