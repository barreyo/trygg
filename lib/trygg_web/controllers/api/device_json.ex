defmodule TryggWeb.Api.DeviceJSON do
  alias Trygg.Devices.{Device, Reading}

  def index(%{devices: devices}), do: %{data: Enum.map(devices, &data/1)}

  def show(%{device: device}), do: %{data: data(device)}

  @doc false
  def data(%Device{} = device) do
    %{
      id: device.id,
      hardware_id: device.hardware_id,
      # Five digits the device shows on its screen so the family can tell units apart.
      short_id: device.short_id,
      # nil until a caregiver names the device in the app.
      name: device.name,
      model: device.model,
      last_seen_at: device.last_seen_at,
      latest: reading(device.latest)
    }
  end

  defp reading(nil), do: nil

  defp reading(%Reading{} = reading) do
    Map.take(reading, [
      :measured_at,
      :temperature_c,
      :humidity_pct,
      :pressure_hpa,
      :gas_ohms,
      :iaq,
      :iaq_accuracy,
      :co2_ppm,
      :voc_ppm
    ])
  end
end
