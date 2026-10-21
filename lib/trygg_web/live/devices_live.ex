defmodule TryggWeb.DevicesLive do
  @moduledoc """
  The family's sensor devices (ENV Pro units on M5Stack buttons): their latest
  temperature, humidity, pressure and air reading, live as samples arrive, and
  the place to name a freshly connected device ("Nursery"), pin it to your own
  Today screen (each member chooses for themselves) or forget it. Each device shows its five-digit id, the same one it
  prints in the corner of its own screen.
  """
  use TryggWeb, :live_view

  import TryggWeb.DeviceComponents, only: [format_air: 1, format_air_detail: 1]

  alias Phoenix.LiveView.JS
  alias Trygg.Devices
  alias Trygg.Devices.Device

  # A device reports about every 30 s; this long without one and it's shown as offline.
  @offline_after_seconds 180
  # How often the "x ago" labels and the offline state are refreshed.
  @tick_ms 20_000

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_child={@current_child}
      children={@children}
      child_switch_to={:devices}
      title="Devices"
      back={~p"/c/#{@current_child}"}
    >
      <.header>
        Room sensors
        <:subtitle>
          Readings from the family's sensor devices, live. A new device shows up here by
          itself; name it so you know which room it is in.
        </:subtitle>
      </.header>

      <div id="devices" phx-update="stream" class="mt-4 space-y-3">
        <div
          id="devices-empty"
          class="hidden only:block rounded-box border border-dashed border-base-300 p-4 text-sm opacity-70"
        >
          No devices yet. Plug an ENV Pro into the button's Port A and flash it with a
          “Read and log” token (Sharing → API access); it registers itself with its first
          reading.
        </div>

        <section
          :for={{dom_id, device} <- @streams.devices}
          id={dom_id}
          class="rounded-box border border-base-300 bg-base-200 p-4"
        >
          <div class="flex items-start gap-2">
            <div class="min-w-0 flex-1">
              <h3 class="truncate font-semibold">
                <.link
                  id={"#{dom_id}-open"}
                  navigate={~p"/c/#{@current_child}/devices/#{device.id}"}
                  class="hover:underline"
                >
                  {Device.label(device)}
                </.link>
              </h3>
              <p class="text-xs opacity-70">
                <span
                  id={"#{dom_id}-short-id"}
                  class="font-mono font-medium"
                  title="This number is also shown in the corner of the device's screen"
                >
                  #{device.short_id}
                </span>
                ·
                <span
                  id={"#{dom_id}-status"}
                  class={[
                    "font-medium",
                    if(online?(device), do: "text-success", else: "text-warning")
                  ]}
                >
                  {if online?(device), do: "Live", else: "Offline"}
                </span>
                · {last_seen(device)}
              </p>
            </div>
            <.button
              :if={@can_edit?}
              id={"#{dom_id}-edit"}
              type="button"
              variant="ghost"
              size="xs"
              aria-label={"Rename #{Device.label(device)}"}
              phx-click={JS.toggle(to: "##{dom_id}-form")}
            >
              <.icon name="hero-pencil-square" class="size-4" />
            </.button>
          </div>

          <dl :if={device.latest} id={"#{dom_id}-readings"} class="mt-3 grid grid-cols-2 gap-3">
            <.metric
              id={"#{dom_id}-temperature"}
              label="Temperature"
              value={temperature(device.latest, @unit_system)}
            />
            <.metric id={"#{dom_id}-humidity"} label="Humidity" value={humidity(device.latest)} />
            <.metric id={"#{dom_id}-pressure"} label="Pressure" value={pressure(device.latest)} />
            <.metric
              id={"#{dom_id}-air"}
              label="Air quality"
              value={format_air(device.latest)}
              title={format_air_detail(device.latest)}
            />
            <.metric id={"#{dom_id}-gas"} label="Gas resistance" value={gas(device.latest)} />
          </dl>
          <p :if={!device.latest} class="mt-3 text-sm opacity-70">No readings yet.</p>
          <.link
            navigate={~p"/c/#{@current_child}/devices/#{device.id}"}
            class="mt-2 inline-flex items-center gap-0.5 text-sm text-primary underline underline-offset-2"
          >
            Graphs and history <.icon name="hero-arrow-right" class="size-3" />
          </.link>

          <label
            id={"#{dom_id}-today"}
            class="mt-3 flex cursor-pointer items-center gap-3 text-sm"
          >
            <input
              type="checkbox"
              id={"#{dom_id}-today-toggle"}
              class="checkbox checkbox-sm"
              checked={device.id in @pinned}
              phx-click="toggle_today"
              phx-value-id={device.id}
            /> Show on my Today
          </label>

          <.form
            :if={@can_edit?}
            for={name_form(device)}
            id={"#{dom_id}-form"}
            phx-submit="name_device"
            class={["mt-3 space-y-2", Device.named?(device) && "hidden"]}
          >
            <input type="hidden" name="device[id]" value={device.id} />
            <.input
              field={name_form(device)[:name]}
              placeholder="Which room is this? e.g. Nursery"
              aria-label="Device name"
              autocomplete="off"
              maxlength="60"
            />
            <div class="flex gap-2">
              <.button variant="primary" size="sm" phx-disable-with="Saving…">
                {if Device.named?(device), do: "Rename", else: "Name device"}
              </.button>
              <.button
                :if={Device.named?(device)}
                type="button"
                variant="ghost"
                size="sm"
                phx-click="delete_device"
                phx-value-id={device.id}
                data-confirm={"Forget “#{Device.label(device)}”? Its readings are deleted; it registers again if it keeps reporting."}
              >
                Forget
              </.button>
            </div>
          </.form>
          <p :if={!@can_edit?} class="mt-3 text-xs opacity-60">{device.hardware_id}</p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :title, :string, default: nil

  defp metric(assigns) do
    ~H"""
    <div id={@id} title={@title}>
      <dt class="text-xs opacity-70">{@label}</dt>
      <dd class="text-xl font-semibold tabular-nums">{@value}</dd>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    family_id = socket.assigns.current_child.family_id

    if connected?(socket) do
      Devices.subscribe(family_id)
      Process.send_after(self(), :tick, @tick_ms)
    end

    {:ok,
     socket
     |> assign(:unit_system, socket.assigns.current_scope.user.unit_system)
     |> assign(:pinned, pinned_ids(socket))
     |> assign_role(socket.assigns.current_child.role)
     |> stream(:devices, list_devices(socket), reset: true)}
  end

  @impl true
  def handle_info({:device_reading, device, _reading}, socket),
    do: {:noreply, stream_insert(socket, :devices, device)}

  def handle_info({:device_changed, device}, socket),
    do: {:noreply, stream_insert(socket, :devices, device)}

  def handle_info({:device_deleted, id}, socket),
    do: {:noreply, stream_delete_by_dom_id(socket, :devices, "devices-#{id}")}

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, stream(socket, :devices, list_devices(socket), reset: true)}
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

  @impl true
  def handle_event("name_device", %{"device" => %{"id" => id} = params}, socket) do
    with {:ok, device} <- fetch_device(socket, id),
         {:ok, _device} <- Devices.name_device(socket.assigns.current_scope, device, params) do
      {:noreply, socket}
    else
      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Give the device a name (up to 60 characters).")}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_today", %{"id" => id}, socket) do
    with {:ok, device} <- fetch_device(socket, id),
         pinned = device.id in socket.assigns.pinned,
         {:ok, device} <- Devices.set_on_today(socket.assigns.current_scope, device, !pinned) do
      # Pinning is this user's own and not broadcast, so redraw the row with the new tick.
      pinned_ids =
        if pinned,
          do: MapSet.delete(socket.assigns.pinned, device.id),
          else: MapSet.put(socket.assigns.pinned, device.id)

      {:noreply, socket |> assign(:pinned, pinned_ids) |> stream_insert(:devices, device)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("delete_device", %{"id" => id}, socket) do
    with {:ok, device} <- fetch_device(socket, id),
         {:ok, _device} <- Devices.delete_device(socket.assigns.current_scope, device) do
      {:noreply, put_flash(socket, :info, "“#{Device.label(device)}” forgotten.")}
    else
      _ -> {:noreply, socket}
    end
  end

  defp fetch_device(socket, id) do
    {:ok,
     Devices.get_device!(
       socket.assigns.current_scope,
       socket.assigns.current_child.family_id,
       id
     )}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp pinned_ids(socket),
    do: Devices.pinned_ids(socket.assigns.current_scope, socket.assigns.current_child.family_id)

  defp list_devices(socket),
    do: Devices.list_devices(socket.assigns.current_scope, socket.assigns.current_child.family_id)

  defp assign_role(socket, role),
    do: socket |> assign(:role, role) |> assign(:can_edit?, role in [:owner, :caregiver])

  defp name_form(device),
    do: to_form(%{"name" => device.name || ""}, as: :device, id: "device-form-#{device.id}")

  ## Presentation ---------------------------------------------------------------

  defp online?(%Device{last_seen_at: nil}), do: false

  defp online?(%Device{last_seen_at: at}),
    do: DateTime.diff(DateTime.utc_now(), at) <= @offline_after_seconds

  defp last_seen(%Device{last_seen_at: nil}), do: "never reported"
  defp last_seen(%Device{last_seen_at: at}), do: "updated #{relative_time(at)}"

  defp temperature(%{temperature_c: nil}, _system), do: "—"

  defp temperature(%{temperature_c: c}, :imperial),
    do: "#{Float.round(c * 9 / 5 + 32, 1)} °F"

  defp temperature(%{temperature_c: c}, _system), do: "#{Float.round(c * 1.0, 1)} °C"

  defp humidity(%{humidity_pct: nil}), do: "—"
  defp humidity(%{humidity_pct: h}), do: "#{round(h)} %"

  defp pressure(%{pressure_hpa: nil}), do: "—"
  defp pressure(%{pressure_hpa: p}), do: "#{round(p)} hPa"

  defp gas(%{gas_ohms: nil}), do: "—"
  defp gas(%{gas_ohms: g}) when g >= 1_000_000, do: "#{Float.round(g / 1_000_000, 1)} MΩ"
  defp gas(%{gas_ohms: g}), do: "#{round(g / 1000)} kΩ"
end
