defmodule TryggWeb.DeviceComponents do
  @moduledoc """
  How a sensor device (`Trygg.Devices.Device`) looks on screen: the readings
  formatted for the family's unit system, and the playful room card that sits
  on the Today screen next to the glance cards.
  """
  use Phoenix.Component

  import TryggWeb.CoreComponents, only: [icon: 1]
  import TryggWeb.LogComponents, only: [relative_time: 1]

  alias Trygg.Devices.{AirQuality, Device}

  # A device reports about every 30 s; this long without one and it's shown as offline.
  @offline_after_seconds 180

  # Paediatric sleep guidance puts a baby's room at 16-20 °C.
  @cool_below_c 16
  @ideal_up_to_c 20
  @warm_up_to_c 24

  ## Formatting -------------------------------------------------------------

  @doc "Whether the device has reported recently enough to count as live."
  def device_online?(%Device{last_seen_at: nil}), do: false

  def device_online?(%Device{last_seen_at: at}),
    do: DateTime.diff(DateTime.utc_now(), at) <= @offline_after_seconds

  @doc "The temperature of a reading in the user's unit system, \"—\" without one."
  def format_temperature(nil, _system), do: "—"
  def format_temperature(%{temperature_c: nil}, _system), do: "—"

  def format_temperature(%{temperature_c: c}, :imperial),
    do: "#{Float.round(c * 9 / 5 + 32, 1)} °F"

  def format_temperature(%{temperature_c: c}, _system), do: "#{Float.round(c * 1.0, 1)} °C"

  @doc "Relative humidity of a reading."
  def format_humidity(%{humidity_pct: h}) when is_number(h), do: "#{round(h)} %"
  def format_humidity(_reading), do: "—"

  @doc "Air pressure of a reading."
  def format_pressure(%{pressure_hpa: p}) when is_number(p), do: "#{round(p)} hPa"
  def format_pressure(_reading), do: "—"

  @doc "Gas (VOC) resistance of a reading: falls as the air gets worse."
  def format_gas(%{gas_ohms: g}) when is_number(g) and g >= 1_000_000,
    do: "#{Float.round(g / 1_000_000, 1)} MΩ"

  def format_gas(%{gas_ohms: g}) when is_number(g), do: "#{round(g / 1000)} kΩ"
  def format_gas(_reading), do: "—"

  @doc """
  How the air is, in a word. A device running BSEC reports an index (0 clean .. 500
  bad) that starts out unreliable and is trusted once its accuracy reaches 1; until
  then it is "Learning…". A device without one falls back to the raw gas resistance.
  """
  def format_air(%{iaq: iaq, iaq_accuracy: acc})
      when is_number(iaq) and is_integer(acc) and acc >= 1,
      do: AirQuality.label(iaq)

  def format_air(%{iaq: iaq}) when is_number(iaq), do: "Learning…"
  def format_air(reading), do: format_gas(reading)

  @doc "The numbers behind `format_air/1`, for a tooltip; `nil` when the reading has no index."
  def format_air_detail(%{iaq: iaq} = reading) when is_number(iaq) do
    [
      "IAQ #{round(iaq)}",
      equivalent("CO₂", Map.get(reading, :co2_ppm)),
      equivalent("VOC", Map.get(reading, :voc_ppm)),
      accuracy_note(Map.get(reading, :iaq_accuracy))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  def format_air_detail(_reading), do: nil

  defp equivalent(_name, nil), do: nil
  defp equivalent(name, ppm) when ppm >= 10, do: "#{name} ≈ #{round(ppm)} ppm"
  defp equivalent(name, ppm), do: "#{name} ≈ #{Float.round(ppm * 1.0, 1)} ppm"

  defp accuracy_note(3), do: nil
  defp accuracy_note(_), do: "still calibrating to this room"

  ## Mood -------------------------------------------------------------------

  # {emoji, call-out, tone}: how the room feels, for the bubble and the pill.
  defp mood(%Device{} = device) do
    case {device_online?(device), device.latest} do
      {false, _} -> {"🔌", "Offline", "base"}
      {true, %{temperature_c: c}} when is_number(c) -> temperature_mood(c)
      {true, _} -> {"🌡️", "Waiting for a reading", "base"}
    end
  end

  defp temperature_mood(c) when c < @cool_below_c, do: {"🥶", "A little cool", "warning"}

  defp temperature_mood(c) when c <= @ideal_up_to_c,
    do: {"😴", "Just right for sleeping", "success"}

  defp temperature_mood(c) when c <= @warm_up_to_c, do: {"🙂", "A little warm", "base"}
  defp temperature_mood(_c), do: {"🥵", "Quite warm", "warning"}

  ## Today widget -------------------------------------------------------------

  @doc """
  A room card for the Today screen: a bubble whose face follows the temperature,
  the big temperature, a call-out pill and little tiles for humidity, pressure
  and air. The corner dot pulses while the device is live, and the card
  re-renders as new readings arrive (the LiveView subscribes to the family's
  devices).
  """
  attr :device, Device, required: true
  attr :unit_system, :atom, default: :metric
  attr :index, :integer, default: 0, doc: "position in the stack, for the staggered entrance"
  attr :now, :any, default: nil, doc: "changes every tick, so \"x ago\" and offline keep up"
  attr :navigate, :string, default: nil, doc: "where tapping the card goes (the device's page)"

  def device_widget(assigns) do
    {emoji, status, tone} = mood(assigns.device)
    online? = device_online?(assigns.device)

    assigns =
      assign(assigns, emoji: emoji, status: status, tone: tone, online?: online?)

    ~H"""
    <div id={"today-device-#{@device.id}"} data-short-id={@device.short_id}>
      <div
        class="glance-card glance-pop glance-device relative"
        data-mood={@tone}
        style={"--d: #{@index * 80}ms"}
      >
        <.link
          :if={@navigate}
          id={"today-device-#{@device.id}-open"}
          navigate={@navigate}
          class="absolute inset-0 z-10 rounded-[inherit] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        >
          <span class="sr-only">Open {Device.label(@device)}</span>
        </.link>
        <.icon
          :if={@navigate}
          name="hero-chevron-right"
          class="absolute right-3 top-3 size-5 opacity-50"
        />
        <div class="flex items-center gap-3">
          <span
            class="glance-bubble"
            style={"--bob-delay: #{@index * 700}ms"}
            aria-hidden="true"
          >
            {@emoji}
          </span>
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-2 text-sm font-bold uppercase tracking-wider opacity-70">
              <span class="truncate">{Device.label(@device)}</span>
              <span
                id={"today-device-#{@device.id}-live"}
                class={["device-dot", @online? && "device-dot-live"]}
                title={if(@online?, do: "Live", else: "Offline")}
                role="img"
                aria-label={if(@online?, do: "Live", else: "Offline")}
              />
            </div>
            <div
              id={"today-device-#{@device.id}-temperature"}
              class="text-3xl font-extrabold leading-[1.1] tracking-tight tabular-nums break-words"
            >
              {format_temperature(@device.latest, @unit_system)}
            </div>
            <div class="text-base leading-snug opacity-80 break-words">
              {updated(@device, @now)}
            </div>
          </div>
        </div>

        <div class="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1.5">
          <span id={"today-device-#{@device.id}-status"} class="glance-pill">{@status}</span>
          <span
            :if={@device.air_alert}
            id={"today-device-#{@device.id}-air-alert"}
            class="glance-pill glance-pill-warning"
            role="status"
            title={air_alert_detail(@device.air_alert)}
          >
            🍃 Air is {@device.air_alert.percent_below} % below usual
          </span>
        </div>

        <dl
          :if={@device.latest}
          id={"today-device-#{@device.id}-readings"}
          class="mt-2 grid grid-cols-3 gap-2"
        >
          <.tile id={"today-device-#{@device.id}-humidity"} emoji="💧" label="Humidity">
            {format_humidity(@device.latest)}
          </.tile>
          <.tile id={"today-device-#{@device.id}-pressure"} emoji="🎈" label="Pressure">
            {format_pressure(@device.latest)}
          </.tile>
          <.tile
            id={"today-device-#{@device.id}-gas"}
            emoji="🍃"
            label="Air"
            title={format_air_detail(@device.latest)}
          >
            {format_air(@device.latest)}
          </.tile>
        </dl>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :emoji, :string, required: true
  attr :label, :string, required: true
  attr :title, :string, default: nil
  slot :inner_block, required: true

  defp tile(assigns) do
    ~H"""
    <div id={@id} class="device-tile" title={@title}>
      <dt class="whitespace-nowrap text-xs font-semibold opacity-70">
        <span aria-hidden="true">{@emoji}</span> {@label}
      </dt>
      <dd class="whitespace-nowrap text-base font-bold tabular-nums leading-tight">
        {render_slot(@inner_block)}
      </dd>
    </div>
    """
  end

  @doc "What the \"air is below usual\" alert compares, in a sentence."
  def air_alert_detail(%{usual_ohms: usual, current_ohms: current}),
    do:
      "Gas resistance #{round(current / 1000)} kΩ now against a usual #{round(usual / 1000)} kΩ " <>
        "(median of the last 7 days). A sustained drop means more airborne compounds than normal; " <>
        "humidity and cooking move it too."

  defp updated(%Device{last_seen_at: nil}, _now), do: "No readings yet"

  defp updated(%Device{} = device, _now) do
    if device_online?(device),
      do: "Live · updated #{relative_time(device.last_seen_at)}",
      else: "Last seen #{relative_time(device.last_seen_at)}"
  end
end
