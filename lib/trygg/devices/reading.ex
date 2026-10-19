defmodule Trygg.Devices.Reading do
  @moduledoc """
  One sample from a `Trygg.Devices.Device`: temperature, humidity, pressure, the
  raw gas sensor resistance and, from a device running Bosch's BSEC, an air quality
  index with its calibration `iaq_accuracy` and CO2/VOC equivalents. The ranges are
  the BME688's own.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "device_readings" do
    field :measured_at, :utc_datetime_usec
    field :temperature_c, :float
    field :humidity_pct, :float
    field :pressure_hpa, :float
    field :gas_ohms, :float
    field :iaq, :float
    field :iaq_accuracy, :integer
    field :co2_ppm, :float
    field :voc_ppm, :float

    belongs_to :device, Trygg.Devices.Device

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @fields [
    :measured_at,
    :temperature_c,
    :humidity_pct,
    :pressure_hpa,
    :gas_ohms,
    :iaq,
    :iaq_accuracy,
    :co2_ppm,
    :voc_ppm
  ]

  @doc false
  def changeset(reading, attrs) do
    reading
    |> cast(attrs, @fields)
    |> validate_required([:measured_at])
    |> validate_any_measurement()
    |> validate_number(:temperature_c, greater_than_or_equal_to: -40, less_than_or_equal_to: 85)
    |> validate_number(:humidity_pct, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:pressure_hpa, greater_than_or_equal_to: 300, less_than_or_equal_to: 1100)
    |> validate_number(:gas_ohms, greater_than_or_equal_to: 0)
    |> validate_number(:iaq, greater_than_or_equal_to: 0, less_than_or_equal_to: 500)
    |> validate_number(:iaq_accuracy, greater_than_or_equal_to: 0, less_than_or_equal_to: 3)
    |> validate_number(:co2_ppm, greater_than_or_equal_to: 0)
    |> validate_number(:voc_ppm, greater_than_or_equal_to: 0)
    |> validate_not_in_future()
  end

  defp validate_any_measurement(changeset) do
    if Enum.any?(@fields -- [:measured_at], &(get_field(changeset, &1) != nil)),
      do: changeset,
      else: add_error(changeset, :temperature_c, "at least one measurement is required")
  end

  # A little slack for a device clock that runs ahead.
  defp validate_not_in_future(changeset) do
    validate_change(changeset, :measured_at, fn :measured_at, at ->
      if DateTime.diff(at, DateTime.utc_now()) > 300,
        do: [measured_at: "can't be in the future"],
        else: []
    end)
  end
end
