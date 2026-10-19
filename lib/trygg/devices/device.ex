defmodule Trygg.Devices.Device do
  @moduledoc """
  A sensor device (an M5Stack with an ENV Pro unit, say) that reports to a family.

  Devices register themselves: the first reading from an unknown `hardware_id`
  creates the row, unnamed, and a caregiver names it afterwards ("Nursery") so
  the family knows which room it is in. `:latest` is not stored; the context
  fills it with the newest `Trygg.Devices.Reading`, and `:air_alert` when the room's
  air has turned clearly worse than usual.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @hardware_id_format ~r/\A[A-Za-z0-9:_-]{1,64}\z/

  schema "devices" do
    field :hardware_id, :string
    # Five digits the device shows on its own screen, so the family can tell units apart.
    field :short_id, :integer
    field :name, :string
    field :model, :string
    field :last_seen_at, :utc_datetime
    # Shown as a widget on the Today screen.
    field :on_today, :boolean, default: false

    field :latest, :any, virtual: true

    # Set for a device on Today whose air is clearly worse than its own usual; see `Trygg.Devices.AirBaseline`.
    field :air_alert, :any, virtual: true

    belongs_to :family, Trygg.Families.Family

    timestamps(type: :utc_datetime)
  end

  @doc "Whether `id` is acceptable as a hardware id (it goes into a URL path)."
  def valid_hardware_id?(id), do: is_binary(id) and Regex.match?(@hardware_id_format, id)

  @doc "A random five-digit short id (10000..99999)."
  def random_short_id, do: Enum.random(10_000..99_999)

  @doc false
  def registration_changeset(device, attrs) do
    device
    |> cast(attrs, [:hardware_id, :model])
    |> put_change(:short_id, random_short_id())
    |> validate_required([:hardware_id])
    |> validate_format(:hardware_id, @hardware_id_format)
    |> validate_length(:model, max: 40)
    |> unique_constraint([:family_id, :hardware_id])
    |> unique_constraint(:short_id, name: :devices_family_id_short_id_index)
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
  def label(%__MODULE__{short_id: id}), do: "New device #{id}"

  def named?(%__MODULE__{name: name}), do: is_binary(name) and name != ""
end
