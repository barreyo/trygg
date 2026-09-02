defmodule TryggWeb.ReportComponents do
  @moduledoc """
  SVG calendars and summary charts for the Reports tab.
  """
  use Phoenix.Component

  import TryggWeb.CoreComponents, only: [icon: 1]

  alias Trygg.Families.Child
  alias Trygg.Reports.Alerts
  alias Trygg.Reports.Day
  alias Trygg.Units
  alias TryggWeb.LogComponents

  @bars_left 30
  @bars_right 314
  @bars_top 10
  @bars_bottom 96
  @bars_width 320
  @bars_height 116

  @today_width 320
  @today_top 8
  @today_plot_h 672
  @today_axis 36
  @today_col_left 40
  @today_col_right 250
  @today_gutter 258

  @week_width 320
  @week_axis 26
  @week_gap 3

  @chart_left 40
  @chart_right 312
  @chart_top 16
  @chart_bottom 118
  @chart_width 320
  @chart_height 148

  @heat_width 320
  @heat_height 132
  @heat_left 16
  @heat_right 304
  @heat_strip_top 28
  @heat_strip_h 76

  ## Today ----------------------------------------------------------------

  attr :id, :string, required: true
  attr :day, Day, required: true
  attr :child, Child, required: true
  attr :selected, :any, default: nil
  attr :unit_system, :atom, default: :metric

  def today_calendar(assigns) do
    plot = plot_today(assigns.day, assigns.child, assigns.selected, assigns.unit_system)
    assigns = assign(assigns, :plot, plot)

    ~H"""
    <svg
      id={@id}
      viewBox={"0 0 #{@plot.width} #{@plot.height}"}
      class="w-full h-auto select-none"
      role="img"
      aria-label={"Sleep calendar for #{Calendar.strftime(@day.date, "%-d %b %Y")}"}
    >
      <rect
        :for={night <- @plot.nights}
        x={@plot.col_left}
        y={night.y}
        width={@plot.col_width}
        height={night.h}
        class="fill-base-content/8"
      />
      <line
        :for={hour <- @plot.hours}
        x1={@plot.col_left}
        y1={hour.y}
        x2={@plot.col_right}
        y2={hour.y}
        class="stroke-base-content/12"
        stroke-width="1"
      />
      <text
        :for={hour <- @plot.hours}
        x={@plot.axis_x}
        y={hour.y + 3}
        text-anchor="end"
        class="fill-base-content/55"
        font-size="9"
      >
        {hour.label}
      </text>

      <g :for={wake <- @plot.wakes} id={"wake-#{wake.id}"}>
        <rect
          :if={wake.selected?}
          x={@plot.col_left}
          y={wake.y}
          width={@plot.col_width}
          height={wake.h}
          class="fill-base-content/6"
        />
        <rect
          x={@plot.col_left}
          y={wake.y}
          width={@plot.col_width}
          height={max(wake.h, 12)}
          class="fill-transparent cursor-pointer"
          phx-click="select_segment"
          phx-value-kind="wake"
          phx-value-id={wake.id}
        />
        <text
          :if={wake.label}
          x={(@plot.col_left + @plot.col_right) / 2}
          y={wake.y + wake.h / 2 + 3}
          text-anchor="middle"
          class="fill-base-content/45"
          font-size="9"
        >
          {wake.label}
        </text>
      </g>

      <g :for={seg <- @plot.sleeps} id={"sleep-#{seg.id}"}>
        <rect
          x={@plot.col_left + 4}
          y={seg.y}
          width={@plot.col_width - 8}
          height={max(seg.h, 2)}
          rx="3"
          class={[
            "fill-primary cursor-pointer",
            seg.running? && "motion-safe:animate-pulse",
            seg.selected? && "stroke-primary-content stroke-2"
          ]}
          phx-click="select_segment"
          phx-value-kind="sleep"
          phx-value-id={seg.id}
        />
        <title>{seg.caption}</title>
      </g>

      <g :for={ev <- @plot.events} id={"event-#{ev.kind}-#{ev.id}"}>
        <circle
          cx={@plot.gutter_x}
          cy={ev.y}
          r="8"
          class="fill-transparent cursor-pointer"
          phx-click="select_segment"
          phx-value-kind={ev.kind}
          phx-value-id={ev.id}
        />
        <text
          x={@plot.gutter_x}
          y={ev.y + 3}
          text-anchor="middle"
          font-size="10"
        >
          {ev.glyph}
        </text>
        <text
          :if={ev.amount}
          x={@plot.gutter_x + 10}
          y={ev.y + 3}
          class="fill-base-content/60"
          font-size="8"
        >
          {ev.amount}
        </text>
      </g>

      <line
        :if={@plot.now_y}
        x1={@plot.col_left}
        y1={@plot.now_y}
        x2={@plot.col_right}
        y2={@plot.now_y}
        class="stroke-error"
        stroke-width="1.5"
      />
      <text
        :if={@plot.now_y}
        x={@plot.col_right + 2}
        y={@plot.now_y + 3}
        class="fill-error"
        font-size="8"
      >
        now
      </text>
    </svg>
    """
  end

  ## Week -----------------------------------------------------------------

  attr :id, :string, required: true
  attr :days, :list, required: true
  attr :child, Child, required: true
  attr :today_date, Date, required: true

  def week_calendar(assigns) do
    plot = plot_week(assigns.days, assigns.child, assigns.today_date)
    assigns = assign(assigns, :plot, plot)

    ~H"""
    <svg
      id={@id}
      viewBox={"0 0 #{@plot.width} #{@plot.height}"}
      class="w-full h-auto select-none"
      role="img"
      aria-label="Sleep calendar for the last 7 days"
    >
      <text
        :for={hour <- @plot.hours}
        x={@plot.axis_x}
        y={hour.y + 3}
        text-anchor="end"
        class="fill-base-content/55"
        font-size="8"
      >
        {hour.label}
      </text>
      <line
        :for={hour <- @plot.hours}
        x1={@plot.grid_left}
        y1={hour.y}
        x2={@plot.width}
        y2={hour.y}
        class="stroke-base-content/10"
        stroke-width="1"
      />

      <g
        :for={col <- @plot.cols}
        id={"week-col-#{col.iso}"}
        class="cursor-pointer"
        phx-click="open_day"
        phx-value-date={col.iso}
      >
        <rect
          x={col.x}
          y={@plot.top}
          width={col.width}
          height={@plot.plot_h}
          class={[
            "fill-transparent",
            col.today? && "stroke-primary/40"
          ]}
          rx="3"
        />
        <rect
          :for={night <- col.nights}
          x={col.x}
          y={night.y}
          width={col.width}
          height={night.h}
          class="fill-base-content/8 pointer-events-none"
        />
        <rect
          :for={seg <- col.sleeps}
          x={col.x + 2}
          y={seg.y}
          width={col.width - 4}
          height={max(seg.h, 1.5)}
          rx="1.5"
          class={[
            "fill-primary pointer-events-none",
            seg.running? && "motion-safe:animate-pulse"
          ]}
        />
        <circle
          :for={ev <- col.events}
          cx={col.x + col.width / 2}
          cy={ev.y}
          r="1.6"
          class={if(ev.kind == :feeding, do: "fill-info", else: "fill-warning")}
        />
        <line
          :if={col.now_y}
          x1={col.x}
          y1={col.now_y}
          x2={col.x + col.width}
          y2={col.now_y}
          class="stroke-error pointer-events-none"
          stroke-width="1"
        />
        <text
          x={col.x + col.width / 2}
          y={@plot.top - 10}
          text-anchor="middle"
          class={[
            "fill-base-content/70",
            col.today? && "fill-primary font-semibold"
          ]}
          font-size="8"
        >
          {col.weekday}
        </text>
        <text
          x={col.x + col.width / 2}
          y={@plot.top - 1}
          text-anchor="middle"
          class="fill-base-content/50"
          font-size="8"
        >
          {col.daynum}
        </text>
        <text
          x={col.x + col.width / 2}
          y={@plot.top + @plot.plot_h + 12}
          text-anchor="middle"
          class="fill-base-content/60"
          font-size="8"
        >
          {col.total_label}
        </text>
      </g>
    </svg>
    """
  end

  ## Sleep trend bars -----------------------------------------------------

  attr :id, :string, required: true
  attr :series, :list, required: true
  attr :slope_label, :string, default: nil
  attr :selected, :string, default: nil
  attr :caption, :string, default: nil

  def sleep_bar_chart(assigns) do
    chart = plot_bars(assigns.series, assigns.selected)
    assigns = assign(assigns, :chart, chart)

    ~H"""
    <div id={@id}>
      <p :if={@chart.empty?} class="opacity-60 text-sm py-8 text-center">Nothing to chart yet.</p>
      <svg
        :if={!@chart.empty?}
        viewBox={"0 0 #{@chart.width} #{@chart.height}"}
        class="w-full h-44 select-none"
        role="img"
        aria-label="Sleep and awake time by day"
      >
        <line
          :for={tick <- @chart.y_ticks}
          x1={@chart.left}
          y1={tick.y}
          x2={@chart.right}
          y2={tick.y}
          class="stroke-base-content/12"
          stroke-width="1"
        />
        <text
          :for={tick <- @chart.y_ticks}
          x={@chart.left - 4}
          y={tick.y + 3}
          text-anchor="end"
          class="fill-base-content/55"
          font-size="9"
        >
          {tick.label}
        </text>
        <g :for={bar <- @chart.bars}>
          <rect
            :if={bar.selected?}
            x={bar.hit_x}
            y={@chart.top}
            width={bar.hit_w}
            height={@chart.bottom - @chart.top}
            class="fill-primary/15"
          />
          <rect
            x={bar.x}
            y={bar.sleep_y}
            width={bar.w}
            height={bar.sleep_h}
            class="fill-primary"
          />
          <rect
            x={bar.x}
            y={bar.wake_y}
            width={bar.w}
            height={bar.wake_h}
            class="fill-base-content/20"
          />
          <rect
            id={"sleep-bar-#{bar.iso}"}
            x={bar.hit_x}
            y={@chart.top}
            width={bar.hit_w}
            height={@chart.bottom - @chart.top}
            class="fill-transparent cursor-pointer"
            phx-click="select_bar"
            phx-value-date={bar.iso}
          />
          <title>{bar.caption}</title>
        </g>
        <polyline
          :if={@chart.polyline}
          fill="none"
          class="stroke-accent"
          stroke-width="1.5"
          stroke-linejoin="round"
          stroke-linecap="round"
          points={@chart.polyline}
        />
        <text
          :for={label <- @chart.x_labels}
          x={label.x}
          y={@chart.bottom + 14}
          text-anchor="middle"
          class="fill-base-content/55"
          font-size="8"
        >
          {label.label}
        </text>
      </svg>
      <p
        :if={!@chart.empty?}
        id={"#{@id}-caption"}
        class={[
          "text-sm text-center mt-1 tabular-nums min-h-5",
          @caption && "font-medium",
          !@caption && "opacity-50 text-xs"
        ]}
      >
        {@caption || "Tap a day for the total · tap again to open it"}
      </p>
      <div
        :if={!@chart.empty?}
        id={"#{@id}-legend"}
        class="flex items-center justify-center gap-4 text-xs mt-2"
      >
        <span class="flex items-center gap-1.5">
          <span class="size-2.5 rounded-sm bg-primary" aria-hidden="true"></span> Sleep
        </span>
        <span class="flex items-center gap-1.5">
          <span class="size-2.5 rounded-sm bg-base-content/20" aria-hidden="true"></span> Awake
        </span>
      </div>
      <p :if={@slope_label} id={"#{@id}-slope"} class="text-xs opacity-60 text-center mt-0.5">
        {@slope_label}
      </p>
    </div>
    """
  end

  ## Alerts -----------------------------------------------------------------

  @doc """
  The plain-language alert cards from `Trygg.Reports.Alerts`. Renders nothing
  when there are no alerts. `links` maps `:vitals` / `:reports` to paths.
  """
  attr :id, :string, required: true
  attr :alerts, :list, required: true
  attr :links, :map, default: %{}
  attr :title, :string, default: nil

  def alerts_list(assigns) do
    ~H"""
    <section :if={@alerts != []} id={@id} class="rounded-box border border-base-300 overflow-hidden">
      <div :if={@title} class="bg-base-200/40 px-3 py-2">
        <h3 class="font-semibold text-sm">{@title}</h3>
      </div>
      <ul class="divide-y divide-base-300">
        <li :for={alert <- @alerts} id={"#{@id}-#{alert.id}"} class="p-3 flex gap-3">
          <span
            class={["mt-1.5 size-2.5 rounded-full shrink-0", severity_dot(alert.severity)]}
            aria-hidden="true"
          >
          </span>
          <div class="min-w-0 flex-1">
            <p class="text-sm font-semibold leading-tight">{alert.title}</p>
            <p class="text-xs opacity-70 mt-0.5 leading-snug">{alert.detail}</p>
            <.link
              :if={alert.link && @links[alert.link]}
              navigate={@links[alert.link]}
              class="text-xs text-primary hover:underline mt-1 inline-flex items-center gap-0.5"
            >
              {link_label(alert.link)} <.icon name="hero-arrow-right" class="size-3" />
            </.link>
          </div>
        </li>
      </ul>
      <p class="text-[11px] opacity-50 px-3 py-1.5 border-t border-base-300">
        {Alerts.disclaimer()}
      </p>
    </section>
    """
  end

  defp severity_dot(:warning), do: "bg-warning"
  defp severity_dot(:notice), do: "bg-info"
  defp severity_dot(_), do: "bg-base-content/30"

  defp link_label(:vitals), do: "Open Vitals"
  defp link_label(:reports), do: "See trends"
  defp link_label(_), do: "Open"

  ## Simple daily bars ------------------------------------------------------

  @doc """
  A compact per-day bar chart for counts or volumes. `series` is a list of
  `%{date, value}`; `baseline` draws a dashed reference line; `format` turns a
  value into a label for tooltips and the axis.
  """
  attr :id, :string, required: true
  attr :series, :list, required: true
  attr :baseline, :any, default: nil
  attr :baseline_label, :string, default: nil
  attr :format, :any, default: nil
  attr :label, :string, default: "Per day"
  attr :highlight_last, :boolean, default: true

  def count_bar_chart(assigns) do
    chart = plot_counts(assigns.series, assigns.baseline, assigns.format || (&to_string/1))
    assigns = assign(assigns, :chart, chart)

    ~H"""
    <div id={@id}>
      <p :if={@chart.empty?} class="opacity-60 text-sm py-6 text-center">Nothing to chart yet.</p>
      <svg
        :if={!@chart.empty?}
        viewBox={"0 0 #{@chart.width} #{@chart.height}"}
        class="w-full h-32 select-none"
        role="img"
        aria-label={@label}
      >
        <line
          :for={tick <- @chart.y_ticks}
          x1={@chart.left}
          y1={tick.y}
          x2={@chart.right}
          y2={tick.y}
          class="stroke-base-content/12"
          stroke-width="1"
        />
        <text
          :for={tick <- @chart.y_ticks}
          x={@chart.left - 4}
          y={tick.y + 3}
          text-anchor="end"
          class="fill-base-content/55"
          font-size="8"
        >
          {tick.label}
        </text>
        <g :for={bar <- @chart.bars} id={"#{@id}-bar-#{bar.iso}"}>
          <rect
            x={bar.x}
            y={bar.y}
            width={bar.w}
            height={bar.h}
            rx="1.5"
            class={[
              if(@highlight_last and bar.last?, do: "fill-primary/60", else: "fill-primary")
            ]}
          />
          <title>{bar.caption}</title>
        </g>
        <line
          :if={@chart.baseline_y}
          x1={@chart.left}
          y1={@chart.baseline_y}
          x2={@chart.right}
          y2={@chart.baseline_y}
          class="stroke-accent"
          stroke-width="1.25"
          stroke-dasharray="4 3"
        />
        <text
          :for={label <- @chart.x_labels}
          x={label.x}
          y={@chart.bottom + 12}
          text-anchor="middle"
          class="fill-base-content/55"
          font-size="8"
        >
          {label.label}
        </text>
      </svg>
      <p
        :if={!@chart.empty? && @chart.baseline_y && @baseline_label}
        id={"#{@id}-baseline"}
        class="text-xs opacity-60 text-center mt-0.5"
      >
        <span class="inline-block w-4 border-t border-dashed border-accent align-middle mr-1"></span>
        {@baseline_label}
      </p>
    </div>
    """
  end

  defp plot_counts([], _baseline, _format), do: %{empty?: true}

  defp plot_counts(series, baseline, format) do
    n = length(series)
    values = Enum.map(series, &(&1.value || 0))
    max_y = Enum.max([Enum.max(values), baseline || 0, 1]) * 1.15
    span = @bars_right - @bars_left
    slot = span / n
    gap = if n == 1, do: 0, else: min(6, slot * 0.3)
    plot_h = @bars_bottom - @bars_top
    y = fn v -> @bars_bottom - v / max_y * plot_h end

    bars =
      series
      |> Enum.with_index()
      |> Enum.map(fn {point, i} ->
        v = point.value || 0
        h = v / max_y * plot_h
        iso = Date.to_iso8601(point.date)

        %{
          iso: iso,
          x: @bars_left + i * slot + gap / 2,
          w: max(slot - gap, 1),
          y: @bars_bottom - h,
          h: h,
          mid_x: @bars_left + i * slot + slot / 2,
          last?: i == n - 1,
          caption: "#{Calendar.strftime(point.date, "%a %-d %b")} · #{format.(v)}"
        }
      end)

    x_labels =
      if n <= 7 do
        Enum.map(bars, fn b ->
          %{x: b.mid_x, label: Calendar.strftime(Date.from_iso8601!(b.iso), "%-d")}
        end)
      else
        [0, div(n - 1, 2), n - 1]
        |> Enum.uniq()
        |> Enum.map(fn i ->
          b = Enum.at(bars, i)
          %{x: b.mid_x, label: Calendar.strftime(Date.from_iso8601!(b.iso), "%-d %b")}
        end)
      end

    step = nice_step(max_y)

    y_ticks =
      0
      |> Stream.iterate(&(&1 + step))
      |> Stream.take_while(&(&1 <= max_y))
      |> Enum.map(fn v -> %{y: y.(v), label: format.(v)} end)

    %{
      empty?: false,
      width: @bars_width,
      height: @bars_height,
      left: @bars_left,
      right: @bars_right,
      top: @bars_top,
      bottom: @bars_bottom,
      bars: bars,
      x_labels: x_labels,
      y_ticks: y_ticks,
      baseline_y: baseline && y.(baseline)
    }
  end

  defp nice_step(max_y) when max_y <= 6, do: 1
  defp nice_step(max_y) when max_y <= 12, do: 2
  defp nice_step(max_y) when max_y <= 30, do: 5
  defp nice_step(max_y) when max_y <= 60, do: 10
  defp nice_step(max_y) when max_y <= 300, do: 50
  defp nice_step(max_y) when max_y <= 600, do: 100
  defp nice_step(max_y) when max_y <= 1500, do: 250
  defp nice_step(_max_y), do: 500

  ## Typical-day heat strip -----------------------------------------------

  attr :id, :string, required: true
  attr :heatmap, :map, default: nil
  attr :child, Child, default: nil
  attr :morning_wake, :map, default: nil
  attr :bedtime, :map, default: nil
  attr :selected, :string, default: nil
  attr :caption, :string, default: nil

  def heat_strip(assigns) do
    plot =
      plot_heat(
        assigns.heatmap,
        assigns.child,
        assigns.morning_wake,
        assigns.bedtime,
        assigns.selected
      )

    assigns = assign(assigns, :plot, plot)

    ~H"""
    <div id={@id}>
      <p :if={!@plot} class="opacity-60 text-sm py-6 text-center">Not enough days yet.</p>
      <svg
        :if={@plot}
        viewBox={"0 0 #{@plot.width} #{@plot.height}"}
        class="w-full h-auto select-none"
        role="img"
        aria-label="Typical sleep times across the day"
      >
        <rect
          :for={band <- @plot.bands}
          :if={band.night?}
          x={band.x}
          y={@plot.strip_top}
          width={band.w}
          height={@plot.strip_h}
          class="fill-base-content/8"
        />
        <g id={"#{@id}-bands"}>
          <text
            :for={band <- @plot.bands}
            :if={band.show_label?}
            id={"#{@id}-band-#{band.key}"}
            x={band.cx}
            y="16"
            text-anchor="middle"
            class="fill-base-content/55"
            font-size="10"
          >
            {band.label}
          </text>
        </g>
        <rect
          :for={bin <- @plot.bins}
          x={bin.x}
          y={@plot.strip_top}
          width={bin.w}
          height={@plot.strip_h}
          class="fill-primary"
          fill-opacity={bin.opacity}
        />
        <rect
          :if={@plot.selected_bin}
          x={@plot.selected_bin.x}
          y={@plot.strip_top}
          width={@plot.selected_bin.w}
          height={@plot.strip_h}
          class="fill-none stroke-base-content"
          stroke-width="1.5"
        />
        <line
          :for={tick <- @plot.ticks}
          x1={tick.x}
          y1={@plot.strip_top}
          x2={tick.x}
          y2={@plot.strip_bottom}
          class={if(tick.major?, do: "stroke-base-content/20", else: "stroke-base-content/10")}
          stroke-width="1"
        />
        <g :for={marker <- @plot.markers}>
          <line
            x1={marker.x}
            y1={@plot.strip_top - 2}
            x2={marker.x}
            y2={@plot.strip_bottom + 2}
            class="stroke-base-content/70"
            stroke-width="1.25"
            stroke-dasharray="3 2.5"
          />
          <polygon
            points={marker_caret(marker.x, @plot.strip_top)}
            class="fill-base-content/80"
          />
        </g>
        <rect
          :for={bin <- @plot.bins}
          id={"heat-bin-#{bin.index}"}
          x={bin.x}
          y={@plot.strip_top}
          width={bin.w}
          height={@plot.strip_h}
          class="fill-transparent cursor-pointer"
          phx-click="select_heat"
          phx-value-index={bin.index}
        >
          <title>{bin.title}</title>
        </rect>
        <g id={"#{@id}-hours"}>
          <line
            :for={tick <- @plot.ticks}
            x1={tick.x}
            y1={@plot.strip_bottom}
            x2={tick.x}
            y2={@plot.strip_bottom + if(tick.major?, do: 6, else: 3)}
            class="stroke-base-content/40"
            stroke-width="1"
          />
          <text
            :for={tick <- @plot.hour_labels}
            x={tick.x}
            y={@plot.strip_bottom + 18}
            text-anchor={tick.anchor}
            class={if(tick.major?, do: "fill-base-content/70", else: "fill-base-content/45")}
            font-size={if(tick.major?, do: "11", else: "9")}
          >
            {tick.label}
          </text>
        </g>
      </svg>
      <p
        :if={@plot}
        id={"#{@id}-caption"}
        class={[
          "text-sm text-center mt-2 tabular-nums min-h-5",
          @caption && "font-medium",
          !@caption && "opacity-50 text-xs"
        ]}
      >
        {@caption || "Tap a time to see how often they're asleep"}
      </p>
      <p
        :if={@plot && @plot.markers != []}
        id={"#{@id}-markers"}
        class="flex flex-wrap items-center justify-center gap-x-4 gap-y-1 text-xs mt-1"
      >
        <span :for={marker <- @plot.markers} class="tabular-nums opacity-80">
          <span class="opacity-60">{marker.kind}</span>
          <span class="font-medium">{marker.clock}</span>
        </span>
      </p>
      <div
        :if={@plot}
        id={"#{@id}-legend"}
        class="flex items-center justify-center gap-2 text-xs mt-3"
      >
        <span class="opacity-55">Rarely asleep</span>
        <span
          class="flex h-3 overflow-hidden rounded-sm border border-base-content/10"
          aria-hidden="true"
        >
          <span class="w-5 bg-primary/15"></span>
          <span class="w-5 bg-primary/40"></span>
          <span class="w-5 bg-primary/70"></span>
          <span class="w-5 bg-primary"></span>
        </span>
        <span class="opacity-55">Usually asleep</span>
      </div>
    </div>
    """
  end

  def heat_bin_caption(nil, _index), do: nil
  def heat_bin_caption(%{heatmap: nil}, _index), do: nil

  def heat_bin_caption(%{heatmap: %{bins: bins}}, index) do
    case Integer.parse(to_string(index)) do
      {i, ""} ->
        case Enum.find(bins, &(&1.index == i)) do
          nil -> nil
          bin -> heat_title(bin)
        end

      _ ->
        nil
    end
  end

  ## Captions -------------------------------------------------------------

  def segment_caption(%Day{} = day, %Child{} = child, {"sleep", id}, _units) do
    case find_sleep(day, id) do
      nil ->
        nil

      seg ->
        dur = LogComponents.format_duration(seg.seconds)
        loc = if seg.location, do: "in #{seg.location}"
        finish = if seg.running?, do: "now", else: Child.local_clock(child, seg.end)
        clock = "#{Child.local_clock(child, seg.start)}–#{finish}"
        title = if seg.running?, do: "Sleeping", else: "Slept #{dur}"
        join_dots([title, clock, loc])
    end
  end

  def segment_caption(%Day{} = day, %Child{} = child, {"wake", id}, _units) do
    case Enum.find(day.wake_segments, &(to_string(&1.id) == to_string(id))) do
      nil ->
        nil

      seg ->
        dur = LogComponents.format_duration(seg.seconds)
        clock = "#{Child.local_clock(child, seg.start)}–#{Child.local_clock(child, seg.end)}"
        join_dots(["Awake #{dur}", clock])
    end
  end

  def segment_caption(%Day{} = day, %Child{} = child, {"feeding", id}, units) do
    case Enum.find(day.feeds, &(to_string(&1.id) == to_string(id))) do
      nil ->
        nil

      ev ->
        amount = Units.format(ev.data["amount_ml"], :volume, units)
        join_dots(["Feed", amount, Child.local_clock(child, ev.at)])
    end
  end

  def segment_caption(%Day{} = day, %Child{} = child, {"diaper", id}, _units) do
    case Enum.find(day.diapers, &(to_string(&1.id) == to_string(id))) do
      nil ->
        nil

      ev ->
        kind = ev.data["kind"]

        join_dots([
          "#{String.capitalize(to_string(kind || "diaper"))} diaper",
          Child.local_clock(child, ev.at)
        ])
    end
  end

  def segment_caption(_day, _child, _sel, _units), do: nil

  ## Plotting -------------------------------------------------------------

  defp plot_today(%Day{} = day, %Child{} = child, selected, units) do
    top = @today_top
    plot_h = @today_plot_h
    {from, to} = day.bounds
    day_seconds = max(DateTime.diff(to, from, :second), 1)
    y = fn offset -> top + offset / day_seconds * plot_h end
    h = fn seconds -> seconds / day_seconds * plot_h end

    %{
      width: @today_width,
      height: top + plot_h + 8,
      top: top,
      plot_h: plot_h,
      axis_x: @today_axis - 4,
      col_left: @today_col_left,
      col_right: @today_col_right,
      col_width: @today_col_right - @today_col_left,
      gutter_x: @today_gutter,
      hours: hour_ticks(child, day, y),
      nights: Enum.map(day.night_shading, fn n -> %{y: y.(n.offset), h: h.(n.seconds)} end),
      sleeps:
        Enum.map(day.sleep_segments, fn s ->
          %{
            id: s.id,
            y: y.(s.offset),
            h: h.(s.seconds),
            running?: s.running?,
            selected?: selected == {"sleep", to_string(s.id)},
            caption: sleep_caption(child, s)
          }
        end),
      wakes:
        Enum.map(day.wake_segments, fn w ->
          %{
            id: w.id,
            y: y.(w.offset),
            h: h.(w.seconds),
            selected?: selected == {"wake", to_string(w.id)},
            label:
              if(w.seconds >= 45 * 60, do: "awake #{LogComponents.format_duration(w.seconds)}")
          }
        end),
      events: plot_events(day, units, y),
      now_y: day.now_offset && y.(day.now_offset)
    }
  end

  defp plot_week(days, %Child{} = child, today_date) do
    top = 22
    plot_h = @today_plot_h
    n = max(length(days), 1)
    grid_left = @week_axis
    usable = @week_width - grid_left
    col_w = (usable - @week_gap * (n - 1)) / n
    # Hour ticks from the last day (today) so DST on an earlier column is close enough.
    axis_day = List.last(days) || hd(days)
    {from, to} = axis_day.bounds
    day_seconds = max(DateTime.diff(to, from, :second), 1)
    y = fn offset -> top + offset / day_seconds * plot_h end

    cols =
      days
      |> Enum.with_index()
      |> Enum.map(fn {day, i} ->
        x = grid_left + i * (col_w + @week_gap)
        {dfrom, dto} = day.bounds
        ds = max(DateTime.diff(dto, dfrom, :second), 1)
        dy = fn offset -> top + offset / ds * plot_h end
        dh = fn seconds -> seconds / ds * plot_h end

        %{
          iso: Date.to_iso8601(day.date),
          x: x,
          width: col_w,
          today?: Date.compare(day.date, today_date) == :eq,
          weekday: Calendar.strftime(day.date, "%a"),
          daynum: Calendar.strftime(day.date, "%-d"),
          total_label: compact_duration(day.total_sleep_seconds),
          nights: Enum.map(day.night_shading, fn n -> %{y: dy.(n.offset), h: dh.(n.seconds)} end),
          sleeps:
            Enum.map(day.sleep_segments, fn s ->
              %{y: dy.(s.offset), h: dh.(s.seconds), running?: s.running?}
            end),
          events:
            Enum.map(day.feeds ++ day.diapers, fn ev ->
              %{y: dy.(ev.offset), kind: ev.entry.type}
            end),
          now_y: day.now_offset && dy.(day.now_offset)
        }
      end)

    %{
      width: @week_width,
      height: top + plot_h + 18,
      top: top,
      plot_h: plot_h,
      axis_x: @week_axis - 3,
      grid_left: grid_left,
      hours: hour_ticks(child, axis_day, y),
      cols: cols
    }
  end

  defp plot_bars([], _selected), do: %{empty?: true}

  defp plot_bars(series, selected) do
    n = length(series)

    max_y =
      series
      |> Enum.map(fn d -> (d.total || 0) + (Map.get(d, :awake) || 0) end)
      |> Enum.max()
      |> max(86_400)

    y_max = max_y
    span = @chart_right - @chart_left
    gap = if n == 1, do: 0, else: min(6, span / n * 0.25)
    bar_slot = span / n
    bar_w = bar_slot - gap

    y = fn seconds ->
      @chart_bottom - seconds / y_max * (@chart_bottom - @chart_top)
    end

    bars =
      series
      |> Enum.with_index()
      |> Enum.map(fn {d, i} ->
        hit_x = @chart_left + i * bar_slot
        x = hit_x + gap / 2
        plot_h = @chart_bottom - @chart_top
        sleep_h = (d.total || 0) / y_max * plot_h
        wake_h = (Map.get(d, :awake) || 0) / y_max * plot_h
        sleep_y = @chart_bottom - sleep_h
        wake_y = sleep_y - wake_h
        iso = Date.to_iso8601(d.date)

        %{
          iso: iso,
          x: x,
          w: max(bar_w, 1),
          hit_x: hit_x,
          hit_w: bar_slot,
          sleep_y: sleep_y,
          sleep_h: sleep_h,
          wake_y: wake_y,
          wake_h: wake_h,
          mid_x: x + bar_w / 2,
          rolling_y: d.rolling && y.(d.rolling),
          selected?: selected == iso,
          caption: sleep_bar_caption(d)
        }
      end)

    polyline =
      bars
      |> Enum.filter(& &1.rolling_y)
      |> case do
        pts when length(pts) >= 2 ->
          Enum.map_join(pts, " ", fn b -> "#{fmt(b.mid_x)},#{fmt(b.rolling_y)}" end)

        _ ->
          nil
      end

    x_labels =
      cond do
        n <= 7 ->
          Enum.map(bars, fn b ->
            date = Date.from_iso8601!(b.iso)
            %{x: b.mid_x, label: Calendar.strftime(date, "%-d")}
          end)

        true ->
          idxs = [0, div(n - 1, 2), n - 1] |> Enum.uniq()

          Enum.map(idxs, fn i ->
            b = Enum.at(bars, i)
            date = Date.from_iso8601!(b.iso)
            %{x: b.mid_x, label: Calendar.strftime(date, "%-d %b")}
          end)
      end

    %{
      empty?: false,
      width: @chart_width,
      height: @chart_height,
      left: @chart_left,
      right: @chart_right,
      top: @chart_top,
      bottom: @chart_bottom,
      y_ticks: y_tick_marks(y_max, y),
      bars: bars,
      polyline: polyline,
      x_labels: x_labels
    }
  end

  def sleep_bar_caption(point) when is_map(point) do
    [
      Calendar.strftime(point.date, "%a %-d %b"),
      "Sleep #{LogComponents.format_duration(point.total)}",
      "Awake #{LogComponents.format_duration(Map.get(point, :awake) || 0)}"
    ]
    |> Enum.join(" · ")
  end

  defp y_tick_marks(y_max, y_fun) do
    hours = max(div(round(y_max), 3600), 1)

    step =
      cond do
        hours <= 6 -> 2
        hours <= 12 -> 3
        true -> 4
      end

    0
    |> Stream.iterate(&(&1 + step))
    |> Stream.take_while(&(&1 * 3600 <= y_max))
    |> Enum.map(fn h ->
      %{y: y_fun.(h * 3600), label: "#{h}h"}
    end)
  end

  defp hour_ticks(%Child{} = child, %Day{} = day, y_fun) do
    {from, _to} = day.bounds

    for h <- 0..22, rem(h, 2) == 0 do
      dt = Child.at_local(child, day.date, Time.new!(h, 0, 0))
      offset = DateTime.diff(dt, from, :second)
      label = :io_lib.format("~2..0B", [h]) |> IO.iodata_to_binary()
      %{hour: h, y: y_fun.(offset), label: label}
    end
  end

  defp plot_events(%Day{} = day, units, y_fun) do
    feeds =
      Enum.map(day.feeds, fn ev ->
        %{
          id: ev.id,
          kind: "feeding",
          y: y_fun.(ev.offset),
          glyph: "🍼",
          amount: Units.format(ev.data["amount_ml"], :volume, units)
        }
      end)

    diapers =
      Enum.map(day.diapers, fn ev ->
        %{
          id: ev.id,
          kind: "diaper",
          y: y_fun.(ev.offset),
          glyph: LogComponents.diaper_emoji(ev.data["kind"]),
          amount: nil
        }
      end)

    Enum.sort_by(feeds ++ diapers, & &1.y)
  end

  defp sleep_caption(%Child{} = child, seg) do
    dur = LogComponents.format_duration(seg.seconds)
    finish = if seg.running?, do: "now", else: Child.local_clock(child, seg.end)
    "#{Child.local_clock(child, seg.start)}–#{finish} · #{dur}"
  end

  defp find_sleep(day, id) do
    Enum.find(day.sleep_segments, &(to_string(&1.id) == to_string(id)))
  end

  defp compact_duration(seconds) when is_integer(seconds) and seconds >= 3600 do
    h = div(seconds, 3600)
    m = rem(div(seconds, 60), 60)
    if m == 0, do: "#{h}h", else: "#{h}h#{m}"
  end

  defp compact_duration(seconds) when is_integer(seconds) and seconds >= 60,
    do: "#{div(seconds, 60)}m"

  defp compact_duration(_), do: "—"

  defp plot_heat(nil, _child, _morning, _bedtime, _selected), do: nil

  defp plot_heat(heatmap, child, morning, bedtime, selected) do
    bins = heatmap.bins
    n = max(length(bins), 1)
    plot_w = @heat_right - @heat_left
    strip_bottom = @heat_strip_top + @heat_strip_h
    selected_index = parse_heat_index(selected)

    plotted =
      Enum.map(bins, fn bin ->
        %{
          index: bin.index,
          x: @heat_left + bin.index / n * plot_w,
          w: plot_w / n + 0.2,
          opacity: max(bin.share, 0.035),
          title: heat_title(bin),
          selected?: selected_index == bin.index
        }
      end)

    %{
      width: @heat_width,
      height: @heat_height,
      strip_top: @heat_strip_top,
      strip_h: @heat_strip_h,
      strip_bottom: strip_bottom,
      bins: plotted,
      selected_bin: Enum.find(plotted, & &1.selected?),
      bands: heat_bands(child, plot_w),
      ticks: heat_ticks(plot_w),
      hour_labels: heat_hour_labels(plot_w),
      markers: heat_markers(morning, bedtime, plot_w)
    }
  end

  defp parse_heat_index(nil), do: nil

  defp parse_heat_index(index) do
    case Integer.parse(to_string(index)) do
      {i, ""} -> i
      _ -> nil
    end
  end

  defp heat_bands(nil, _plot_w), do: []

  defp heat_bands(%Child{} = child, plot_w) do
    day_h = time_hours(child.day_start)
    night_h = time_hours(child.night_start)

    ranges =
      if day_h < night_h do
        [
          %{from: 0, to: day_h, label: "Night", night?: true, key: "night-am"},
          %{from: day_h, to: night_h, label: "Day", night?: false, key: "day"},
          %{from: night_h, to: 24, label: "Night", night?: true, key: "night-pm"}
        ]
      else
        [
          %{from: 0, to: night_h, label: "Day", night?: false, key: "day-am"},
          %{from: night_h, to: day_h, label: "Night", night?: true, key: "night"},
          %{from: day_h, to: 24, label: "Day", night?: false, key: "day-pm"}
        ]
      end

    Enum.map(ranges, fn band ->
      w = (band.to - band.from) / 24 * plot_w
      x = @heat_left + band.from / 24 * plot_w

      Map.merge(band, %{
        x: x,
        w: w,
        cx: x + w / 2,
        show_label?: w >= 36
      })
    end)
    |> Enum.reject(&(&1.w < 1))
  end

  defp heat_ticks(plot_w) do
    for hour <- 0..24 do
      %{
        hour: hour,
        x: @heat_left + hour / 24 * plot_w,
        major?: rem(hour, 6) == 0
      }
    end
  end

  defp heat_hour_labels(plot_w) do
    for hour <- 0..24, rem(hour, 3) == 0 do
      major? = rem(hour, 6) == 0

      %{
        hour: hour,
        x: @heat_left + hour / 24 * plot_w,
        label: heat_hour_label(hour, major?),
        major?: major?,
        anchor:
          cond do
            hour == 0 -> "start"
            hour == 24 -> "end"
            true -> "middle"
          end
      }
    end
  end

  defp heat_hour_label(24, _major?), do: "24:00"
  defp heat_hour_label(hour, true), do: "#{pad2(hour)}:00"
  defp heat_hour_label(hour, false), do: pad2(hour)

  defp heat_markers(morning, bedtime, plot_w) do
    [
      heat_marker("Wake", morning, plot_w),
      heat_marker("Bed", bedtime, plot_w)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp heat_marker(_kind, %{median_minutes: nil}, _plot_w), do: nil
  defp heat_marker(_kind, nil, _plot_w), do: nil

  defp heat_marker(kind, %{median_minutes: minutes, median_label: clock}, plot_w) do
    hour = rem(round(minutes), 24 * 60) / 60

    %{
      kind: kind,
      clock: clock,
      x: @heat_left + hour / 24 * plot_w
    }
  end

  defp marker_caret(x, y) do
    "#{x},#{y - 1} #{x - 3.5},#{y - 7} #{x + 3.5},#{y - 7}"
  end

  defp time_hours(%Time{} = time) do
    time.hour + time.minute / 60 + time.second / 3600
  end

  defp heat_title(%{hour: hour, share: share}) do
    start_min = round(hour * 60)
    stop_min = start_min + 30
    pct = round(share * 100)
    "#{minutes_clock(start_min)}–#{minutes_clock(stop_min)} · asleep #{pct}% of days"
  end

  defp minutes_clock(minutes) when minutes >= 24 * 60, do: "24:00"

  defp minutes_clock(minutes) do
    minutes = rem(minutes, 24 * 60)
    "#{pad2(div(minutes, 60))}:#{pad2(rem(minutes, 60))}"
  end

  defp pad2(n), do: :io_lib.format("~2..0B", [n]) |> IO.iodata_to_binary()

  defp join_dots(parts) do
    parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")
  end

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  defp fmt(n), do: n
end
