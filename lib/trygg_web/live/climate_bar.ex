defmodule TryggWeb.ClimateBar do
  @moduledoc """
  The thin strip at the top of every child screen while a room sensor is connected:
  painted green, yellow, orange or red by how good the air is, with the room's
  temperature in its left corner. A sensor whose air index is still calibrating (or
  that has none) gets a neutral strip, and with no sensor online there is no strip.

  `Layouts.app` renders this as a live component, so no page has to know about it.
  The `on_mount` hook (after `TryggWeb.ChildScope`) subscribes the LiveView to the
  family's device messages and forwards them here, and ticks so a sensor that has gone
  quiet drops off. It lets the messages carry on to the page, which may want them too,
  and it is the only subscriber: pages must not subscribe to the same topic again.

  With several sensors online the oldest one is shown, so the strip does not flip
  between rooms as their readings interleave.
  """
  use TryggWeb, :live_component

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, send_update: 2]
  import TryggWeb.DeviceComponents, only: [air_level: 1, device_online?: 1, format_temperature: 2]

  alias Trygg.Devices
  alias Trygg.Devices.{AirQuality, Device}

  @id "climate-bar"
  @tick_ms 30_000

  ## Hook -----------------------------------------------------------------------

  def on_mount(:default, _params, _session, socket) do
    case socket.assigns[:current_child] do
      %{family_id: family_id} when is_integer(family_id) ->
        if connected?(socket) do
          Devices.subscribe(family_id)
          Process.send_after(self(), :climate_tick, @tick_ms)
        end

        {:cont, attach_hook(socket, :climate_bar, :handle_info, &forward/2)}

      _ ->
        {:cont, socket}
    end
  end

  defp forward(:climate_tick, socket) do
    Process.send_after(self(), :climate_tick, @tick_ms)
    send_update(__MODULE__, id: @id, event: :tick)
    {:halt, socket}
  end

  defp forward({:device_reading, _device, _reading} = message, socket), do: relay(message, socket)
  defp forward({:device_changed, _device} = message, socket), do: relay(message, socket)
  defp forward({:device_deleted, _id} = message, socket), do: relay(message, socket)
  defp forward(_message, socket), do: {:cont, socket}

  defp relay(message, socket) do
    send_update(__MODULE__, id: @id, event: message)
    {:cont, socket}
  end

  ## Component ------------------------------------------------------------------

  @impl true
  def update(%{event: event}, socket), do: {:ok, apply_event(socket, event)}

  # The layout re-renders this with the same assigns on every page update; the devices are
  # only loaded once, the messages from the hook keep them current.
  def update(assigns, socket) do
    socket = assign(socket, Map.take(assigns, [:current_scope, :current_child]))

    if Map.has_key?(socket.assigns, :devices) do
      {:ok, socket}
    else
      %{current_scope: scope, current_child: child} = socket.assigns
      devices = Devices.list_devices(scope, child.family_id, alerts: false)
      {:ok, assign(socket, devices: Map.new(devices, &{&1.id, &1}), now: DateTime.utc_now())}
    end
  end

  defp apply_event(socket, :tick), do: assign(socket, :now, DateTime.utc_now())

  defp apply_event(socket, {:device_deleted, id}),
    do: update(socket, :devices, &Map.delete(&1, id))

  defp apply_event(socket, {:device_reading, device, _reading}), do: put_device(socket, device)
  defp apply_event(socket, {:device_changed, device}), do: put_device(socket, device)

  defp put_device(socket, %Device{} = device),
    do:
      socket
      |> update(:devices, &Map.put(&1, device.id, device))
      |> assign(:now, DateTime.utc_now())

  # `now` only makes a tick re-render; liveness is judged against the clock in `device_online?/1`.
  defp sensor(devices) do
    devices
    |> Map.values()
    |> Enum.filter(&(device_online?(&1) and &1.latest != nil))
    |> Enum.min_by(& &1.id, fn -> nil end)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :sensor, sensor(assigns.devices))

    ~H"""
    <div id="climate-bar">
      <.link
        :if={@sensor}
        id="climate-bar-link"
        navigate={~p"/c/#{@current_child}/devices/#{@sensor.id}"}
        class="climate-bar"
        data-air={air_level(@sensor.latest) || "unknown"}
      >
        <span id="climate-bar-temperature" class="tabular-nums">
          {format_temperature(@sensor.latest, @current_scope.user.unit_system)}
        </span>
        <span class="sr-only">
          in {Device.label(@sensor)}, air quality {air_word(@sensor.latest)}
        </span>
      </.link>
    </div>
    """
  end

  defp air_word(%{iaq: iaq, iaq_accuracy: acc}) when is_number(iaq) and acc in 1..3,
    do: AirQuality.label(iaq)

  defp air_word(_reading), do: "still being measured"
end
