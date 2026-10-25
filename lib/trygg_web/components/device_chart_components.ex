defmodule TryggWeb.DeviceChartComponents do
  @moduledoc """
  Line graphs of a sensor device's readings over time, for the device detail page.

  `specs/1` lists the measurements, `build/3` turns a `Trygg.Devices.history/3`
  result into the geometry for one of them, and `reading_chart/1` draws it. The SVG
  is rendered on the server (so it updates live with the readings); the
  `DeviceChart` hook only moves a crosshair and a readout across it, from the
  points embedded in `data-points`, so scrubbing never waits on the connection.
  """
  use Phoenix.Component

  alias Trygg.Devices.AirQuality
  alias Trygg.TimeFormat

  @width 320
  @height 150
  @left 42
  @right 312
  @top 10
  @bottom 128

  # How long a hole in the readings has to be (in buckets) before the line breaks
  # instead of bridging it, e.g. while the device was unplugged.
  @gap_buckets 3

  @doc """
  The measurements to graph, in display order. Each is `%{field, id, label, emoji,
  color, unit, decimals, convert}`: `field` is the reading's key, `convert` maps its
  stored value to the number shown (°C → °F, Ω → kΩ), and `color` is a CSS color.
  A spec with a `needs` key (a reading field) is only graphed for a device that reports
  it, see `shown?/2`. One with `bands` (`Trygg.Devices.AirQuality.bands/0`) is drawn over
  tinted regions and names the band a value falls in; `include` lists values the axis
  must always cover, so the regions around the data show even when it barely moves.
  """
  def specs(unit_system) do
    {temp_unit, temp_convert} =
      if unit_system == :imperial,
        do: {"°F", &(&1 * 9 / 5 + 32)},
        else: {"°C", & &1}

    [
      %{
        field: :temperature_c,
        id: "temperature",
        label: "Temperature",
        emoji: "🌡️",
        color: "var(--color-device)",
        unit: temp_unit,
        decimals: 1,
        convert: temp_convert
      },
      %{
        field: :humidity_pct,
        id: "humidity",
        label: "Humidity",
        emoji: "💧",
        color: "var(--color-info)",
        unit: "%",
        decimals: 0,
        convert: & &1
      },
      %{
        field: :pressure_hpa,
        id: "pressure",
        label: "Pressure",
        emoji: "🎈",
        color: "var(--color-primary)",
        unit: "hPa",
        decimals: 1,
        convert: & &1
      },
      %{
        field: :gas_ohms,
        id: "air",
        label: "Gas resistance",
        emoji: "🍃",
        color: "var(--color-success)",
        unit: "kΩ",
        decimals: 0,
        convert: &(&1 / 1000)
      },
      %{
        field: :iaq,
        id: "iaq",
        needs: :iaq,
        label: "Air quality index",
        emoji: "🌬️",
        color: "var(--color-base-content)",
        unit: "IAQ",
        decimals: 0,
        convert: & &1,
        bands: AirQuality.bands(),
        include: [0, 100]
      },
      %{
        field: :co2_ppm,
        id: "co2",
        needs: :iaq,
        label: "CO₂ equivalent",
        emoji: "🫁",
        color: "var(--color-secondary)",
        unit: "ppm",
        decimals: 0,
        convert: & &1
      }
    ]
  end

  @doc """
  Whether a device's page graphs `spec`: always, unless it `needs` a field the device
  has never reported (the air quality graphs mean nothing for a unit without BSEC).
  """
  def shown?(%{needs: field}, device), do: Map.get(device.latest || %{}, field) != nil
  def shown?(_spec, _device), do: true

  ## Geometry -----------------------------------------------------------------

  @doc """
  Geometry for one measurement: `%{empty?: true}` when nothing in the window
  reported it, else `%{y_ticks, x_ticks, segments, lone, points, low, high}`.
  `history` is `Trygg.Devices.history/3`'s result and `tz` the IANA zone the time
  labels are shown in.
  """
  def build(history, spec, tz) do
    values =
      Enum.flat_map(history.points, fn point ->
        case Map.get(point, spec.field) do
          v when is_number(v) ->
            [%{unix: DateTime.to_unix(point.at), at: point.at, v: spec.convert.(v)}]

          _ ->
            []
        end
      end)

    if values == [], do: %{empty?: true}, else: build_values(values, history, spec, tz)
  end

  defp build_values(values, history, spec, tz) do
    x_min = DateTime.to_unix(history.from)
    x_max = DateTime.to_unix(history.to)
    span = x_max - x_min
    {y_ticks, lo, hi} = nice_ticks(Enum.map(values, & &1.v) ++ Map.get(spec, :include, []))

    placed =
      Enum.map(values, fn p ->
        Map.merge(p, %{
          x: round1(@left + (p.unix - x_min) / span * (@right - @left)),
          y: round1(@bottom - (p.v - lo) / (hi - lo) * (@bottom - @top))
        })
      end)

    # The buckets are equally wide, so their mean is the window's mean.
    average = Enum.sum_by(values, & &1.v) / length(values)

    runs = split_runs(placed, history.bucket * @gap_buckets)
    {lone, lines} = Enum.split_with(runs, &match?([_], &1))

    long_range? = span > 86_400 * 2

    %{
      empty?: false,
      y_ticks:
        Enum.map(y_ticks, fn t ->
          %{
            y: round1(@bottom - (t - lo) / (hi - lo) * (@bottom - @top)),
            label: tick_label(t, y_ticks)
          }
        end),
      bands: bands(spec, lo, hi),
      x_ticks: x_ticks(history, span, tz),
      segments:
        Enum.map(lines, fn run ->
          line = Enum.map_join(run, " ", &"#{&1.x},#{&1.y}")
          first = hd(run)
          last = List.last(run)
          %{line: line, area: "#{line} #{last.x},#{@bottom} #{first.x},#{@bottom}"}
        end),
      lone: Enum.map(lone, fn [p] -> %{x: p.x, y: p.y} end),
      # What the hook scrubs through: [x, y, "when", "value"] per point.
      points:
        Enum.map(placed, fn p ->
          [p.x, p.y, when_label(p.at, tz, long_range?), reading_text(p.v, spec)]
        end),
      low: format(Enum.min_by(values, & &1.v).v, spec),
      high: format(Enum.max_by(values, & &1.v).v, spec),
      avg: format(average, spec),
      avg_y: round1(@bottom - (average - lo) / (hi - lo) * (@bottom - @top))
    }
  end

  # The tinted regions behind a graph with bands, clipped to the axis: the y and height
  # in the plot, and where its label goes.
  defp bands(%{bands: bands}, lo, hi) do
    for band <- bands, band.to > lo, band.from < hi do
      top = min(band.to, hi)
      bottom = max(band.from, lo)
      y = @bottom - (top - lo) / (hi - lo) * (@bottom - @top)
      height = (top - bottom) / (hi - lo) * (@bottom - @top)

      %{
        y: round1(y),
        height: round1(height),
        label: band.label,
        label_y: round1(y + min(height, 12) / 2 + 3),
        style: "fill: var(--color-#{band.tone}); fill-opacity: #{band.opacity}"
      }
    end
  end

  defp bands(_spec, _lo, _hi), do: []

  # A value as shown while scrubbing, with the band's word when the graph has bands.
  defp reading_text(value, %{bands: _} = spec) do
    band = Enum.find(spec.bands, List.last(spec.bands), &(value <= &1.to))
    "#{format(value, spec)} · #{band.label}"
  end

  defp reading_text(value, spec), do: format(value, spec)

  # Consecutive points, broken wherever the readings stop for longer than `gap` seconds.
  defp split_runs(points, gap) do
    points
    |> Enum.reduce([], fn
      p, [[prev | _] = run | rest] when p.unix - prev.unix <= gap -> [[p | run] | rest]
      p, acc -> [[p] | acc]
    end)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
  end

  # Round gridline values that cover the data: the step is 1, 2, 2.5, 5 or 10 times a
  # power of ten, about three gridlines apart.
  defp nice_ticks(values) do
    {min, max} = Enum.min_max(values)
    {min, max} = if max - min < 1.0e-9, do: {min - 1.0, max + 1.0}, else: {min * 1.0, max * 1.0}

    raw = (max - min) / 3
    magnitude = :math.pow(10, Float.floor(:math.log10(raw)))
    step = Enum.find([1, 2, 2.5, 5, 10], &(&1 * magnitude >= raw)) * magnitude

    lo = Float.floor(min / step) * step
    hi = Float.ceil(max / step) * step
    ticks = for i <- 0..round((hi - lo) / step), do: lo + i * step
    {ticks, lo, hi}
  end

  # As many decimals as the gridline spacing needs, so 1009.5 and 1010.0 don't both read "1010".
  defp tick_label(value, [a, b | _]) do
    step = abs(b - a)
    decimals = if step >= 1, do: 0, else: min(ceil(-:math.log10(step)), 2)
    :erlang.float_to_binary(value * 1.0, decimals: decimals)
  end

  defp format(value, %{decimals: 0, unit: unit}), do: "#{round(value)} #{unit}"

  defp format(value, %{decimals: n, unit: unit}),
    do: "#{:erlang.float_to_binary(value * 1.0, decimals: n)} #{unit}"

  defp when_label(at, tz, long_range?) do
    local = DateTime.shift_zone!(at, tz)

    Calendar.strftime(
      local,
      if(long_range?, do: "%a %-d %b · " <> TimeFormat.pattern(), else: TimeFormat.pattern())
    )
  end

  defp round1(n), do: Float.round(n * 1.0, 1)

  ## Time axis ----------------------------------------------------------------

  # {gridline spacing in seconds, label format} for the window's length.
  defp x_step(span) when span <= 6 * 3600, do: {3600, TimeFormat.pattern()}
  defp x_step(span) when span <= 24 * 3600, do: {6 * 3600, TimeFormat.pattern()}
  defp x_step(span) when span <= 7 * 86_400, do: {86_400, "%a %-d"}
  defp x_step(_span), do: {7 * 86_400, "%-d %b"}

  # Gridlines on round local times (whole hours, midnights) from `from` to `to`.
  defp x_ticks(history, span, tz) do
    {step, format} = x_step(span)
    x_min = DateTime.to_unix(history.from)
    local_from = DateTime.shift_zone!(history.from, tz)

    times =
      if step < 86_400 do
        midnight = local_midnight(DateTime.to_date(local_from), tz)
        for k <- 0..div(span + 86_400, step), do: DateTime.add(midnight, k * step, :second)
      else
        days = div(step, 86_400)
        date = DateTime.to_date(local_from)
        for k <- 0..(div(span, step) + 1), do: local_midnight(Date.add(date, k * days), tz)
      end

    for t <- times,
        unix = DateTime.to_unix(t),
        unix >= x_min,
        unix <= DateTime.to_unix(history.to) do
      x = round1(@left + (unix - x_min) / span * (@right - @left))
      %{x: x, label: Calendar.strftime(DateTime.shift_zone!(t, tz), format)}
    end
  end

  defp local_midnight(date, tz) do
    case DateTime.new(date, ~T[00:00:00], tz) do
      {:ok, dt} -> dt
      {:ambiguous, first, _second} -> first
      {:gap, _before, after_gap} -> after_gap
    end
  end

  ## Rendering ----------------------------------------------------------------

  attr :id, :string, required: true
  attr :spec, :map, required: true, doc: "one of `specs/1`"
  attr :chart, :map, required: true, doc: "`build/3`'s result for that spec"
  attr :hint, :string, default: nil, doc: "a line of small print under the graph"

  def reading_chart(assigns) do
    assigns = assign(assigns, width: @width, height: @height, left: @left, right: @right)
    assigns = assign(assigns, top: @top, bottom: @bottom)

    ~H"""
    <section
      id={@id}
      class="rounded-[var(--radius-card)] border-2 bg-base-200/60 p-3"
      style={"color: #{@spec.color}; border-color: color-mix(in oklab, #{@spec.color} 35%, transparent)"}
    >
      <h3 class="flex items-center gap-2 text-sm font-bold uppercase tracking-wider text-base-content/80">
        <span aria-hidden="true">{@spec.emoji}</span> {@spec.label}
        <span class="text-xs font-semibold normal-case tracking-normal opacity-70">
          {@spec.unit}
        </span>
      </h3>

      <p
        :if={@chart.empty?}
        id={"#{@id}-empty"}
        class="py-10 text-center text-sm text-base-content/70"
      >
        Nothing reported in this period.
      </p>

      <div
        :if={!@chart.empty?}
        id={"#{@id}-plot"}
        phx-hook="DeviceChart"
        data-points={Jason.encode!(@chart.points)}
        data-width={@width}
        class="mt-1"
      >
        <svg
          viewBox={"0 0 #{@width} #{@height}"}
          class="h-44 w-full touch-pan-y select-none"
          role="img"
          aria-label={"#{@spec.label} over time in #{@spec.unit}, from #{@chart.low} to #{@chart.high}, average #{@chart.avg}"}
        >
          <g :for={band <- @chart.bands} data-band={band.label}>
            <rect x={@left} y={band.y} width={@right - @left} height={band.height} style={band.style} />
            <text
              x={@right - 3}
              y={band.label_y}
              text-anchor="end"
              class="fill-base-content/60"
              font-size="8"
              font-weight="600"
            >
              {band.label}
            </text>
          </g>
          <line
            :for={tick <- @chart.y_ticks}
            x1={@left}
            y1={tick.y}
            x2={@right}
            y2={tick.y}
            class="stroke-base-content/12"
            stroke-width="1"
          />
          <line
            :for={tick <- @chart.x_ticks}
            x1={tick.x}
            y1={@top}
            x2={tick.x}
            y2={@bottom}
            class="stroke-base-content/12"
            stroke-width="1"
          />
          <text
            :for={tick <- @chart.y_ticks}
            x={@left - 4}
            y={tick.y + 3}
            text-anchor="end"
            class="fill-base-content/70"
            font-size="9"
          >
            {tick.label}
          </text>
          <text
            :for={tick <- @chart.x_ticks}
            x={tick.x}
            y={@bottom + 14}
            text-anchor="middle"
            class="fill-base-content/70"
            font-size="9"
          >
            {tick.label}
          </text>

          <line
            id={"#{@id}-avg-line"}
            x1={@left}
            y1={@chart.avg_y}
            x2={@right}
            y2={@chart.avg_y}
            stroke="currentColor"
            stroke-opacity="0.55"
            stroke-width="1"
            stroke-dasharray="4 3"
          />
          <polygon
            :for={segment <- @chart.segments}
            points={segment.area}
            fill="currentColor"
            fill-opacity="0.16"
          />
          <polyline
            :for={segment <- @chart.segments}
            points={segment.line}
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linejoin="round"
            stroke-linecap="round"
          />
          <circle :for={dot <- @chart.lone} cx={dot.x} cy={dot.y} r="2.5" fill="currentColor" />

          <g data-crosshair class="hidden" pointer-events="none">
            <line
              data-crosshair-line
              y1={@top}
              y2={@bottom}
              stroke="currentColor"
              stroke-opacity="0.5"
              stroke-dasharray="3 3"
            />
            <circle
              data-crosshair-dot
              r="4.5"
              fill="currentColor"
              class="stroke-base-100"
              stroke-width="2"
            />
          </g>
        </svg>
      </div>

      <p
        :if={!@chart.empty?}
        id={"#{@id}-readout"}
        data-readout
        data-default={"Low #{@chart.low} · Avg #{@chart.avg} · High #{@chart.high}"}
        class="min-h-5 text-center text-sm font-semibold tabular-nums"
      >
        Low {@chart.low} · Avg {@chart.avg} · High {@chart.high}
      </p>
      <p :if={@hint} class="mt-1 text-center text-xs text-base-content/70">{@hint}</p>
    </section>
    """
  end
end
