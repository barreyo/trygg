defmodule TryggWeb.Api.DeviceController do
  @moduledoc """
  Sensor devices (the M5Stack ENV Pro) reporting to the token's family. Reading
  needs a `viewer` token, reporting a `caregiver` one (anything else is a `403`).

    * `GET  /api/v1/devices` — the family's devices, each with its latest reading
    * `POST /api/v1/devices/:hardware_id/readings` — `temperature_c`,
      `humidity_pct`, `pressure_hpa`, `gas_ohms`, `iaq`, `iaq_accuracy`,
      `co2_ppm`, `voc_ppm` (any of them), an optional
      `measured_at` (ISO 8601, defaults to now) and `model`. A `hardware_id` the
      family hasn't seen registers a new, unnamed device; a caregiver names it in
      the app. Viewers of the app see the reading live.
  """
  use TryggWeb, :controller

  alias Trygg.Devices

  action_fallback TryggWeb.Api.FallbackController

  @writable ~w(temperature_c humidity_pct pressure_hpa gas_ohms iaq iaq_accuracy co2_ppm voc_ppm
                 measured_at model)

  def index(conn, _params) do
    scope = conn.assigns.current_scope
    render(conn, :index, devices: Devices.list_devices(scope, scope.api_token.family_id))
  end

  def create(conn, %{"hardware_id" => hardware_id} = params) do
    scope = conn.assigns.current_scope

    with {:ok, %{device: device}} <-
           Devices.record_reading(
             scope,
             scope.api_token.family_id,
             hardware_id,
             Map.take(params, @writable)
           ) do
      conn
      |> put_status(:created)
      |> render(:show, device: device)
    end
  end
end
