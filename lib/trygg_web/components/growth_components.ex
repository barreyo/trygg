defmodule TryggWeb.GrowthComponents do
  @moduledoc """
  Weight / height trend charts with CDC percentile bands, shared by the Vitals
  screen and the printable report.

  `build_chart/8` turns measurements into SVG geometry; `trend_chart/1`
  renders it. Pass `static` to drop the tap targets and hint caption when the
  output isn't interactive (PDF).
  """
  use Phoenix.Component

  alias Trygg.Families.Child
  alias Trygg.Growth.Percentiles
  alias Trygg.Units

  @plot_left 46
  @plot_right 312
  @plot_top 24
  @plot_bottom 126

  # Narrow → wide. Zoom in/out walks this list; chips pick a step directly.
  @periods [
    {:weeks_2, "2w", 14},
    {:month_1, "1m", 30},
    {:months_3, "3m", 90},
    {:months_6, "6m", 180},
    {:year_1, "1y", 365},
    {:all, "All", nil}
  ]

  @doc "The zoom periods as `{id, label, days | nil}`."
  def periods, do: @periods

  attr :id, :string, required: true
  attr :kind, :string, required: true
  attr :title, :string, required: true
  attr :unit, :string, required: true
  attr :chart, :map, required: true
  attr :static, :boolean, default: false

  def trend_chart(assigns) do
    ~H"""
    <div id={@id} class="p-3">
      <div class="flex items-baseline justify-between mb-1">
        <h3 class="font-semibold text-sm">{@title}</h3>
        <span class="text-xs opacity-60">
          {@unit}
          <span :if={@chart.show_bands} class="opacity-70"> · CDC 5th–95th</span>
        </span>
      </div>
      <p :if={@chart.empty?} class="opacity-60 text-sm py-8 text-center">Nothing to chart yet.</p>
      <p :if={@chart.empty_range?} class="opacity-60 text-sm py-8 text-center">
        None in this period.
      </p>
      <svg
        :if={!@chart.empty? and !@chart.empty_range?}
        viewBox="0 0 320 172"
        class="w-full h-48 select-none"
        role="img"
        aria-label={"#{@title} over time in #{@unit}"}
      >
        <line
          :for={tick <- @chart.y_ticks}
          x1="46"
          y1={tick.y}
          x2="312"
          y2={tick.y}
          class="stroke-base-content/12"
          stroke-width="1"
        />
        <line
          :for={tick <- @chart.x_ticks}
          x1={tick.x}
          y1="24"
          x2={tick.x}
          y2="126"
          class="stroke-base-content/12"
          stroke-width="1"
        />
        <line
          :for={tick <- @chart.age_ticks}
          x1={tick.x}
          y1="24"
          x2={tick.x}
          y2="126"
          class={if(tick.year?, do: "stroke-base-content/35", else: "stroke-base-content/20")}
          stroke-width="1"
          stroke-dasharray={if tick.year?, do: nil, else: "3 3"}
        />
        <line x1="46" y1="24" x2="46" y2="126" class="stroke-base-content/25" stroke-width="1" />
        <line x1="46" y1="126" x2="312" y2="126" class="stroke-base-content/25" stroke-width="1" />

        <g :if={@chart.show_bands} id={"#{@id}-bands"}>
          <polygon :if={@chart.band_fill} points={@chart.band_fill} class="fill-base-content/10" />
          <polyline
            :if={@chart.p5}
            fill="none"
            class="stroke-base-content/25"
            stroke-width="1"
            points={@chart.p5}
          />
          <polyline
            :if={@chart.p95}
            fill="none"
            class="stroke-base-content/25"
            stroke-width="1"
            points={@chart.p95}
          />
          <polyline
            :if={@chart.p50}
            fill="none"
            class="stroke-base-content/40"
            stroke-width="1"
            stroke-dasharray="4 3"
            points={@chart.p50}
          />
          <text
            :for={label <- @chart.band_labels}
            x={label.x}
            y={label.y}
            text-anchor="end"
            class="fill-base-content/45"
            font-size="8"
          >
            {label.text}
          </text>
        </g>

        <text
          :for={tick <- @chart.y_ticks}
          x="42"
          y={tick.y + 3}
          text-anchor="end"
          class="fill-base-content/55"
          font-size="9"
        >
          {tick.label}
        </text>
        <g id={"#{@id}-ages"}>
          <text
            :for={tick <- @chart.age_ticks}
            x={tick.x}
            y="16"
            text-anchor="middle"
            class={[
              "fill-base-content/70",
              tick.year? && "font-semibold"
            ]}
            font-size="9"
          >
            {tick.label}
          </text>
        </g>
        <text
          :for={tick <- @chart.x_ticks}
          x={tick.x}
          y="140"
          text-anchor={tick.anchor}
          class="fill-base-content/55"
          font-size="9"
        >
          {tick.label}
        </text>
        <g id={"#{@id}-age-axis"}>
          <text
            :for={tick <- @chart.x_ticks}
            :if={tick.age}
            x={tick.x}
            y="154"
            text-anchor={tick.anchor}
            class="fill-base-content/70"
            font-size="9"
          >
            {tick.age}
          </text>
        </g>

        <polygon
          :if={!@chart.show_bands and @chart.area}
          points={@chart.area}
          class="fill-primary/15"
        />
        <polyline
          :if={@chart.polyline}
          fill="none"
          class="stroke-primary"
          stroke-width="2"
          stroke-linejoin="round"
          stroke-linecap="round"
          points={@chart.polyline}
        />

        <g :for={dot <- @chart.dots} id={"#{@id}-point-#{dot.id}"}>
          <circle
            :if={!@static}
            cx={dot.x}
            cy={dot.y}
            r="20"
            class="fill-transparent cursor-pointer"
            phx-click="select_point"
            phx-value-chart={@kind}
            phx-value-id={dot.id}
          />
          <circle
            :if={dot.selected?}
            cx={dot.x}
            cy={dot.y}
            r="8"
            class="fill-none stroke-primary"
            stroke-width="1.5"
          />
          <circle cx={dot.x} cy={dot.y} r={if(dot.selected?, do: 5, else: 3.5)} class="fill-primary" />
          <title>{dot.caption}</title>
        </g>
      </svg>
      <p
        :if={!@static and !@chart.empty? and !@chart.empty_range?}
        id={"#{@id}-caption"}
        class={[
          "text-sm text-center mt-1 tabular-nums min-h-5",
          @chart.caption && "font-medium",
          !@chart.caption && "opacity-50 text-xs"
        ]}
      >
        {@chart.caption || "Tap a point for the reading"}
      </p>
    </div>
    """
  end

  ## Chart geometry ---------------------------------------------------------

  @doc """
  Builds the chart map consumed by `trend_chart/1`.

  `field` is `:weight_g` or `:height_cm`; `kind` is the matching `Trygg.Units`
  kind (`:weight` / `:length`). `from`/`to` bound the visible window. Options:

    * `:selected` — `{chart_kind, id_string}` of the highlighted point
    * `:chart_kind` — the string used in `:selected` (`"weight"` / `"height"`)
  """
  def build_chart(measurements, field, kind, units, %Child{} = child, from, to, opts \\ []) do
    selected = Keyword.get(opts, :selected)
    chart_kind = Keyword.get(opts, :chart_kind)

    all =
      measurements
      |> Enum.reverse()
      |> Enum.flat_map(fn m ->
        case Map.get(m, field) do
          v when is_number(v) ->
            date = local_date(child, m.measured_at)
            display = Units.to_display(v, kind, units)

            [
              %{
                id: m.id,
                date: date,
                value: display,
                caption: point_caption(child, date, v, kind, units)
              }
            ]

          _ ->
            []
        end
      end)

    in_range =
      Enum.filter(all, fn p ->
        not Date.before?(p.date, from) and not Date.after?(p.date, to)
      end)

    cond do
      all == [] ->
        %{empty?: true, empty_range?: false, show_bands: false}

      in_range == [] ->
        %{empty?: false, empty_range?: true, show_bands: false}

      true ->
        x_min = unix_on(child, from)
        x_max = unix_on(child, to)
        bands = percentile_bands(child, kind, units, from, to)
        band_ys = Enum.flat_map(bands, fn {_p, pts} -> Enum.map(pts, &elem(&1, 1)) end)
        ys = Enum.map(in_range, & &1.value)
        {y_min, y_max} = y_bounds(ys ++ band_ys)

        dots =
          Enum.map(in_range, fn p ->
            %{
              id: p.id,
              x: scale_x(unix_on(child, p.date), x_min, x_max),
              y: scale_y(p.value, y_min, y_max),
              caption: p.caption,
              selected?: selected == {chart_kind, to_string(p.id)}
            }
          end)

        selected_caption = Enum.find_value(dots, fn d -> if d.selected?, do: d.caption end)
        show_bands = band_ys != []

        svg_bands =
          Map.new(bands, fn {p, pts} ->
            {p, svg_points(pts, child, x_min, x_max, y_min, y_max)}
          end)

        p5 = polyline(svg_bands[5] || [])
        p50 = polyline(svg_bands[50] || [])
        p95 = polyline(svg_bands[95] || [])

        %{
          empty?: false,
          empty_range?: false,
          show_bands: show_bands,
          dots: dots,
          polyline: polyline(dots),
          area: area(dots),
          band_fill: band_polygon(svg_bands[5], svg_bands[95]),
          p5: p5,
          p50: p50,
          p95: p95,
          band_labels: band_labels(svg_bands),
          y_ticks: y_tick_marks(y_min, y_max),
          x_ticks: x_tick_marks(child, from, to, x_min, x_max),
          age_ticks: age_ticks(child, from, to, x_min, x_max),
          caption: selected_caption
        }
    end
  end

  @doc """
  `{from, to}` local dates for a zoom `period` (see `periods/0`). `:all` starts
  at the earliest measurement, never later than two weeks ago.
  """
  def date_window(%Child{} = child, period, measurements) do
    today = Child.local_today(child)
    days = Enum.find_value(@periods, fn {id, _, d} -> if id == period, do: d end)

    from =
      cond do
        is_integer(days) ->
          Date.add(today, 1 - days)

        true ->
          case earliest_date(child, measurements) do
            nil -> Date.add(today, -13)
            first -> earliest_all_start(first, today)
          end
      end

    {from, today}
  end

  @doc "\"3 Jan – 12 Feb 2026\" style label for a date window."
  def window_label(from, to) do
    if Date.compare(from, to) == :eq do
      Calendar.strftime(to, "%-d %b %Y")
    else
      "#{Calendar.strftime(from, "%-d %b")} – #{Calendar.strftime(to, "%-d %b %Y")}"
    end
  end

  @doc "\"3d\", \"4mo\", \"1y 2mo\" from a `Child.age/2` tuple."
  def compact_age(nil), do: nil
  def compact_age({0, 0, 0}), do: "0d"
  def compact_age({0, 0, d}), do: "#{d}d"
  def compact_age({0, m, _d}), do: "#{m}mo"
  def compact_age({y, 0, _d}), do: "#{y}y"
  def compact_age({y, m, _d}), do: "#{y}y #{m}mo"

  @doc "The child's local calendar date of a UTC instant."
  def local_date(%Child{timezone: tz}, %DateTime{} = dt) do
    dt |> DateTime.shift_zone!(tz) |> DateTime.to_date()
  end

  defp earliest_all_start(first, today) do
    floor = Date.add(today, -13)
    if Date.before?(first, floor), do: first, else: floor
  end

  defp earliest_date(_child, []), do: nil

  defp earliest_date(child, measurements) do
    measurements
    |> Enum.map(&local_date(child, &1.measured_at))
    |> Enum.min(Date)
  end

  defp percentile_bands(child, kind, units, from, to) do
    Map.new(Percentiles.band_percentiles(), fn p ->
      pts =
        child
        |> Percentiles.curve(kind, p, from, to)
        |> Enum.map(fn {date, canonical} ->
          {date, Units.to_display(canonical, kind, units)}
        end)

      {p, pts}
    end)
  end

  defp svg_points(pts, child, x_min, x_max, y_min, y_max) do
    Enum.map(pts, fn {date, value} ->
      %{
        x: scale_x(unix_on(child, date), x_min, x_max),
        y: scale_y(value, y_min, y_max)
      }
    end)
  end

  defp band_polygon(p5, p95)
       when is_list(p5) and is_list(p95) and length(p5) >= 2 and length(p95) >= 2 do
    top = Enum.map_join(p95, " ", fn d -> "#{fmt(d.x)},#{fmt(d.y)}" end)
    bottom = p5 |> Enum.reverse() |> Enum.map_join(" ", fn d -> "#{fmt(d.x)},#{fmt(d.y)}" end)
    "#{top} #{bottom}"
  end

  defp band_polygon(_p5, _p95), do: nil

  defp band_labels(svg_bands) do
    [
      {5, "5th", 6},
      {50, "50th", -4},
      {95, "95th", -4}
    ]
    |> Enum.flat_map(fn {p, text, dy} ->
      case svg_bands |> Map.get(p, []) |> List.last() do
        %{x: x, y: y} -> [%{x: x - 2, y: y + dy, text: text}]
        _ -> []
      end
    end)
  end

  defp unix_on(%Child{} = child, %Date{} = date) do
    {start, _} = Child.day_bounds(child, date)
    DateTime.to_unix(start)
  end

  defp y_bounds(ys) do
    min = Enum.min(ys)
    max = Enum.max(ys)
    span = max - min
    pad = if span == 0, do: max(abs(min) * 0.08, 0.1), else: span * 0.18
    {min - pad, max + pad}
  end

  defp y_tick_marks(min, max) do
    count = 4

    for i <- 0..(count - 1) do
      value = min + i * (max - min) / (count - 1)
      %{y: scale_y(value, min, max), label: trim_number(Float.round(value, 2))}
    end
  end

  defp x_tick_marks(child, from, to, x_min, x_max) do
    days = Date.diff(to, from)
    count = if days < 3, do: 2, else: 3

    for i <- 0..(count - 1) do
      date = Date.add(from, round(i * days / max(count - 1, 1)))

      anchor =
        cond do
          i == 0 -> "start"
          i == count - 1 -> "end"
          true -> "middle"
        end

      %{
        x: scale_x(unix_on(child, date), x_min, x_max),
        label: Calendar.strftime(date, "%-d %b"),
        age: compact_age(Child.age(child, date)),
        anchor: anchor
      }
    end
  end

  defp point_caption(child, date, value, kind, units) do
    percentile =
      child
      |> Percentiles.percentile(kind, value, date)
      |> Percentiles.format_percentile()

    [
      Calendar.strftime(date, "%-d %b %Y"),
      Units.format(value, kind, units),
      compact_age(Child.age(child, date)),
      percentile
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp age_ticks(%Child{birth_date: nil}, _from, _to, _x_min, _x_max), do: []

  defp age_ticks(%Child{birth_date: dob} = child, from, to, x_min, x_max) do
    0
    |> Stream.iterate(&(&1 + 1))
    |> Stream.map(&{&1, add_months(dob, &1)})
    |> Stream.take_while(fn {_n, date} -> not Date.after?(date, to) end)
    |> Enum.reject(fn {_n, date} -> Date.before?(date, from) end)
    |> thin_age_ticks()
    |> Enum.map(fn {n, date} ->
      %{
        x: scale_x(unix_on(child, date), x_min, x_max),
        label: anniversary_label(n),
        year?: n > 0 and rem(n, 12) == 0
      }
    end)
    |> Enum.reject(fn tick -> tick.x < @plot_left + 10 or tick.x > @plot_right - 10 end)
  end

  defp thin_age_ticks(ticks) when length(ticks) <= 6, do: ticks

  defp thin_age_ticks(ticks) do
    years = Enum.filter(ticks, fn {n, _} -> n == 0 or rem(n, 12) == 0 end)

    if length(years) >= 2 do
      years
    else
      Enum.filter(ticks, fn {n, _} -> n == 0 or rem(n, 3) == 0 end)
    end
  end

  defp anniversary_label(0), do: "birth"
  defp anniversary_label(n) when n < 12, do: "#{n}mo"
  defp anniversary_label(n) when rem(n, 12) == 0, do: "#{div(n, 12)}y"
  defp anniversary_label(n), do: "#{div(n, 12)}y #{rem(n, 12)}mo"

  defp add_months(%Date{year: year, month: month, day: day}, n) do
    total = year * 12 + (month - 1) + n
    new_year = div(total, 12)
    new_month = rem(total, 12) + 1
    last = Date.days_in_month(%Date{year: new_year, month: new_month, day: 1})
    Date.new!(new_year, new_month, min(day, last))
  end

  defp polyline([]), do: nil
  defp polyline([_]), do: nil

  defp polyline(dots) do
    Enum.map_join(dots, " ", fn d -> "#{fmt(d.x)},#{fmt(d.y)}" end)
  end

  defp area(dots) when length(dots) < 2, do: nil

  defp area(dots) do
    first = List.first(dots)
    last = List.last(dots)
    line = Enum.map_join(dots, " ", fn d -> "#{fmt(d.x)},#{fmt(d.y)}" end)
    "#{line} #{fmt(last.x)},#{@plot_bottom} #{fmt(first.x)},#{@plot_bottom}"
  end

  defp scale_x(_x, min, max) when min == max, do: (@plot_left + @plot_right) / 2

  defp scale_x(x, min, max) do
    @plot_left + (x - min) / (max - min) * (@plot_right - @plot_left)
  end

  defp scale_y(_y, min, max) when min == max, do: (@plot_top + @plot_bottom) / 2

  defp scale_y(y, min, max) do
    @plot_top + (1 - (y - min) / (max - min)) * (@plot_bottom - @plot_top)
  end

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  defp fmt(n), do: n

  defp trim_number(n) when is_float(n) do
    if n == Float.round(n), do: trunc(n), else: n
  end

  defp trim_number(n), do: n
end
