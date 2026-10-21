defmodule TryggWeb.DeviceLive do
  @moduledoc """
  One sensor device: its current readings, live, and a graph of each measurement
  (temperature, humidity, pressure, gas resistance and, for a unit running BSEC, the
  air quality index and CO₂ equivalent) over the last 6 hours, 24 hours, 7 days
  or 30 days. Reached from the Devices page and from the device's card on Today.
  """
  use TryggWeb, :live_view

  import TryggWeb.DeviceComponents, only: [air_alert_detail: 1, device_widget: 1]

  alias Trygg.Devices
  alias TryggWeb.DeviceChartComponents, as: Charts

  @default_range "24h"
  # How often the graphs and "x ago" labels catch up, readings or not.
  @tick_ms 30_000

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_child={@current_child}
      children={@children}
      child_switch_to={:devices}
      title={Trygg.Devices.Device.label(@device)}
      back={~p"/c/#{@current_child}/devices"}
    >
      <p id="device-short-id" class="text-sm text-base-content/70">
        Device <span class="font-mono font-semibold">#{@device.short_id}</span>
        · the number in the corner of its screen
      </p>

      <div class="mt-3">
        <.device_widget device={@device} unit_system={@unit_system} now={@now_tick} />
      </div>

      <p
        :if={@device.air_alert}
        id="device-air-alert"
        class="mt-3 rounded-[var(--radius-field)] border-2 border-warning/40 bg-warning/10 p-3 text-sm"
        role="status"
      >
        <strong>Air is {@device.air_alert.percent_below} % below usual.</strong>
        {air_alert_detail(@device.air_alert)}
      </p>

      <p
        :if={calibrating?(@device)}
        id="device-air-calibrating"
        class="mt-3 text-sm text-base-content/70"
      >
        The air quality index is still learning this room. It is rough for the first hours and settles
        over a few days; opening a window now and then helps it find clean air.
      </p>

      <nav id="device-ranges" class="mt-5 flex gap-2" aria-label="Time range">
        <.link
          :for={{param, label, _seconds} <- @ranges}
          id={"device-range-#{param}"}
          patch={~p"/c/#{@current_child}/devices/#{@device.id}?range=#{param}"}
          aria-current={param == @range && "true"}
          aria-label={"Last #{label}"}
          class={[
            "btn btn-sm flex-1 rounded-full",
            if(param == @range, do: "btn-primary", else: "btn-ghost bg-base-200")
          ]}
        >
          {param}
        </.link>
      </nav>

      <div id="device-charts" class="mt-4 space-y-4">
        <Charts.reading_chart
          :for={{spec, chart} <- @charts}
          id={"device-chart-#{spec.id}"}
          spec={spec}
          chart={chart}
          hint={hint(spec)}
        />
      </div>
    </Layouts.app>
    """
  end

  # Raw gas resistance only says which way the air is going, not how good it is.
  defp hint(%{id: "air"}), do: "Lower means more compounds in the air. Read it as a trend."

  defp hint(%{id: "iaq"}),
    do: "Lower is cleaner. The shading marks the bands; the index is learned per room."

  defp hint(%{id: "co2"}),
    do: "An estimate from the gas sensor, not a CO₂ measurement. Use it as a ventilation cue."

  defp hint(_spec), do: nil

  @impl true
  def mount(%{"device_id" => device_id}, _session, socket) do
    case fetch_device(socket, device_id) do
      {:ok, device} ->
        if connected?(socket) do
          Devices.subscribe(device.family_id)
          Process.send_after(self(), :tick, @tick_ms)
        end

        {:ok,
         socket
         |> assign(:device, device)
         |> assign(:unit_system, socket.assigns.current_scope.user.unit_system)
         |> assign(:ranges, Devices.history_ranges())
         |> assign(:range, @default_range)
         |> assign(:now_tick, System.system_time(:second))
         |> assign(:charts, [])}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "We couldn't find that device.")
         |> push_navigate(to: ~p"/c/#{socket.assigns.current_child}/devices")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    range = if valid_range?(params["range"]), do: params["range"], else: @default_range
    {:noreply, socket |> assign(:range, range) |> load_charts()}
  end

  @impl true
  def handle_info({:device_reading, %{id: id} = device, _reading}, socket)
      when id == socket.assigns.device.id do
    {:noreply, socket |> assign(:device, device) |> load_charts()}
  end

  def handle_info({:device_changed, %{id: id} = device}, socket)
      when id == socket.assigns.device.id,
      do: {:noreply, assign(socket, :device, device)}

  def handle_info({:device_deleted, id}, socket) when id == socket.assigns.device.id do
    {:noreply,
     socket
     |> put_flash(:error, "That device was forgotten.")
     |> push_navigate(to: ~p"/c/#{socket.assigns.current_child}/devices")}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, socket |> assign(:now_tick, System.system_time(:second)) |> load_charts()}
  end

  def handle_info({:child_updated, child}, socket),
    do: {:noreply, assign(socket, :current_child, %{child | role: socket.assigns.role})}

  def handle_info({:child_deleted, _child_id}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "#{socket.assigns.current_child.name} was deleted.")
     |> push_navigate(to: ~p"/")}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp calibrating?(%{latest: %{iaq: iaq, iaq_accuracy: acc}}) when is_number(iaq),
    do: is_nil(acc) or acc < 3

  defp calibrating?(_device), do: false

  defp valid_range?(param), do: Enum.any?(Devices.history_ranges(), &(elem(&1, 0) == param))

  defp load_charts(socket) do
    %{device: device, range: range, current_scope: scope} = socket.assigns
    {_param, _label, seconds} = List.keyfind(socket.assigns.ranges, range, 0)
    history = Devices.history(scope, device, seconds)
    tz = socket.assigns.current_child.timezone

    charts =
      for spec <- Charts.specs(socket.assigns.unit_system),
          Charts.shown?(spec, device),
          do: {spec, Charts.build(history, spec, tz)}

    assign(socket, :charts, charts)
  end

  defp fetch_device(socket, id) do
    {:ok,
     Devices.get_device!(
       socket.assigns.current_scope,
       socket.assigns.current_child.family_id,
       id
     )}
  rescue
    Ecto.NoResultsError -> :error
    Ecto.Query.CastError -> :error
  end
end
