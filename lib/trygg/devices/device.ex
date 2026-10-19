defmodule Trygg.Devices.Device do
  @moduledoc """
  A sensor device (an M5Stack with an ENV Pro unit, say) that reports to a family.

  Devices register themselves: the first reading from an unknown `hardware_id`
  creates the row, unnamed, and a caregiver names it afterwards ("Nursery") so
  the family knows which room it is in. `:latest` is not stored; the context
  fills it with the newest `Trygg.Devices.Reading`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @hardware_id_format ~r/\A[A-Za-z0-9:_-]{1,64}\z/

  schema "devices" do
    field :hardware_id, :string
    field :name, :string
    field :model, :string
    field :last_seen_at, :utc_datetime

    field :latest, :any, virtual: true

    belongs_to :family, Trygg.Families.Family

    timestamps(type: :utc_datetime)
  end

  @doc "Whether `id` is acceptable as a hardware id (it goes into a URL path)."
  def valid_hardware_id?(id), do: is_binary(id) and Regex.match?(@hardware_id_format, id)

  @doc false
  def registration_changeset(device, attrs) do
    device
    |> cast(attrs, [:hardware_id, :model])
    |> validate_required([:hardware_id])
    |> validate_format(:hardware_id, @hardware_id_format)
    |> validate_length(:model, max: 40)
    |> unique_constraint([:family_id, :hardware_id])
  end

  @doc false
  def name_changeset(device, attrs) do
    device
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 60)
  end

  @doc "What to call the device in the UI."
  def label(%__MODULE__{name: name}) when is_binary(name) and name != "", do: name
  def label(%__MODULE__{hardware_id: id}), do: "New device " <> String.slice(id, -5, 5)

  def named?(%__MODULE__{name: name}), do: is_binary(name) and name != ""
end
