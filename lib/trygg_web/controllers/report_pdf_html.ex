defmodule TryggWeb.ReportPdfHTML do
  @moduledoc """
  The printable report: a standalone HTML document (compiled app CSS inlined,
  light theme) that `TryggWeb.ReportPdfController` hands to ChromicPDF.

  `document/1` returns the full page as iodata; `report/1` is the body so tests
  can render it without Chrome. Charts are the same SVG components the Reports
  and Vitals tabs use, in `static` mode.
  """
  use TryggWeb, :html

  require Logger

  alias Trygg.Families.Child
  alias Trygg.Growth.Percentiles
  alias Trygg.Reports.Alerts
  alias Trygg.Reports.Norms
  alias Trygg.Reports.Shifts
  alias Trygg.Units
  alias TryggWeb.GrowthComponents

  @css_path "priv/static/assets/css/app.css"

  @print_css """
  @page { size: A4; margin: 14mm; }
  html, body { background: #fff; }
  body { font-size: 11px; line-height: 1.35; }
  .pdf { max-width: 182mm; margin: 0 auto; }
  .pdf-card { break-inside: avoid; }
  .pdf-title { break-after: avoid; }
  .pdf svg { height: auto !important; }
  .pdf table { font-size: 10px; }
  /* The 7-day calendar is portrait (320x712); pin its height so the row stays on one page. */
  .pdf #pdf-week-calendar { height: 105mm !important; width: auto; display: block; margin: 0 auto; }
  """

  @doc """
  The complete HTML document for the export as iodata.

  Assigns: `child`, `unit_system`, `export` (from `Trygg.Reports.export/4`).
  """
  def document(assigns) do
    # Calling a function component outside HEEx needs the change-tracking key.
    body =
      assigns
      |> Map.put(:__changed__, nil)
      |> report()
      |> Phoenix.HTML.Safe.to_iodata()

    [
      ~s(<!DOCTYPE html><html lang="en" data-theme="light"><head><meta charset="utf-8">),
      ~s(<title>Trygg report</title><style>),
      app_css(),
      "\n",
      @print_css,
      "</style></head><body>",
      body,
      "</body></html>"
    ]
  end

  @doc "The compiled Tailwind stylesheet, or an empty string when assets aren't built."
  # sobelow_skip ["Traversal.FileModule"]
  # `path` is built from the hardcoded `@css_path`, not from any request input.
  def app_css do
    path = Application.app_dir(:trygg, @css_path)

    case File.read(path) do
      {:ok, css} ->
        css

      {:error, reason} ->
        Logger.warning("report PDF: app.css not found at #{path} (#{inspect(reason)})")
        ""
    end
  end

  attr :child, Child, required: true
  attr :unit_system, :atom, required: true
  attr :export, :map, required: true

  def report(assigns) do
    child = assigns.child
    units = assigns.unit_system
    export = assigns.export
    summary = export.summary
    measurements = export.measurements
    {from, to} = GrowthComponents.date_window(child, :all, measurements)

    assigns =
      assigns
      |> assign(:summary, summary)
      |> assign(:feeding, summary.feeding)
      |> assign(:diapers, summary.diapers)
      |> assign(:velocity, summary.growth)
      |> assign(:measurements, measurements)
      |> assign(:window_label, series_label(summary.totals.per_day) || window_name(export.window))
      |> assign(:growth_label, GrowthComponents.window_label(from, to))
      |> assign(:percentile_note, Percentiles.source_label(child))
      |> assign(
        :weight_chart,
        GrowthComponents.build_chart(measurements, :weight_g, :weight, units, child, from, to)
      )
      |> assign(
        :height_chart,
        GrowthComponents.build_chart(measurements, :height_cm, :length, units, child, from, to)
      )
      |> assign(
        :weight_percentile,
        measurement_percentile(export.latest_weight, :weight_g, child)
      )
      |> assign(
        :height_percentile,
        measurement_percentile(export.latest_height, :height_cm, child)
      )

    ~H"""
    <main id="pdf-report" class="pdf text-base-content space-y-5">
      <.report_header
        child={@child}
        export={@export}
        window_label={@window_label}
        unit_system={@unit_system}
      />

      <.summary_cards
        summary={@summary}
        feeding={@feeding}
        latest_weight={@export.latest_weight}
        latest_height={@export.latest_height}
        weight_percentile={@weight_percentile}
        height_percentile={@height_percentile}
        child={@child}
        unit_system={@unit_system}
      />

      <.growth_section
        child={@child}
        unit_system={@unit_system}
        weight_chart={@weight_chart}
        height_chart={@height_chart}
        velocity={@velocity}
        measurements={@measurements}
        growth_label={@growth_label}
        percentile_note={@percentile_note}
      />

      <.sleep_section summary={@summary} child={@child} export={@export} />

      <.feeding_section feeding={@feeding} unit_system={@unit_system} />

      <.diapers_section diapers={@diapers} />

      <.changes_section shifts={@summary.shifts} />

      <section :if={@summary.alerts != []} id="pdf-alerts" class="pdf-card">
        <.alerts_list id="pdf-alert-list" title="Worth a look" alerts={@summary.alerts} />
      </section>

      <footer id="pdf-footer" class="text-[10px] opacity-60 border-t border-base-300 pt-2 space-y-1">
        <p>{Alerts.disclaimer()}</p>
        <p>{Norms.kcal_note()}</p>
        <p :if={@percentile_note}>Growth percentiles: {@percentile_note}.</p>
        <p>
          Sleep, feeding and diaper figures use medians over the window; "varies by" is the
          interquartile range. Generated by Trygg.
        </p>
      </footer>
    </main>
    """
  end

  ## Header --------------------------------------------------------------------

  attr :child, Child, required: true
  attr :export, :map, required: true
  attr :window_label, :string, default: nil
  attr :unit_system, :atom, required: true

  defp report_header(assigns) do
    child = assigns.child
    local_generated = DateTime.shift_zone!(assigns.export.generated_at, child.timezone)

    assigns =
      assigns
      |> assign(:age_label, age_label(Child.age(child, assigns.export.today)))
      |> assign(:sex_label, sex_label(child.sex))
      |> assign(:generated_label, Calendar.strftime(local_generated, "%-d %b %Y, %H:%M"))

    ~H"""
    <header id="pdf-header" class="pdf-card border-b border-base-300 pb-3">
      <div class="flex items-end justify-between gap-4">
        <div>
          <p class="text-xs uppercase tracking-wide opacity-60">Trygg · Growth &amp; sleep report</p>
          <h1 id="pdf-child-name" class="text-2xl font-bold leading-tight mt-0.5">{@child.name}</h1>
          <p class="text-sm opacity-80 mt-0.5">
            {[
              @sex_label,
              @age_label,
              @child.birth_date && "born #{Calendar.strftime(@child.birth_date, "%-d %b %Y")}"
            ]
            |> Enum.reject(&is_nil/1)
            |> Enum.join(" · ")}
          </p>
        </div>
        <dl class="text-right text-xs opacity-70 space-y-0.5 tabular-nums">
          <div>
            <dt class="inline">Window</dt>
            <dd id="pdf-window" class="inline font-medium text-base-content">{@window_label}</dd>
          </div>
          <div>
            <dt class="inline">Generated</dt>
            <dd class="inline font-medium text-base-content">{@generated_label}</dd>
          </div>
          <div>
            <dt class="inline">Day</dt>
            <dd class="inline font-medium text-base-content">
              {Child.format_clock(@child.day_start)} – {Child.format_clock(@child.night_start)}
            </dd>
          </div>
        </dl>
      </div>
    </header>
    """
  end

  ## Summary cards -------------------------------------------------------------

  attr :summary, :map, required: true
  attr :feeding, :map, required: true
  attr :latest_weight, :any, default: nil
  attr :latest_height, :any, default: nil
  attr :weight_percentile, :string, default: nil
  attr :height_percentile, :string, default: nil
  attr :child, Child, required: true
  attr :unit_system, :atom, required: true

  defp summary_cards(assigns) do
    kcal = assigns.feeding.ml.median && Norms.estimated_kcal(assigns.feeding.ml.median)
    assigns = assign(assigns, :kcal_label, kcal && "~#{round(kcal)} kcal")

    ~H"""
    <section id="pdf-summary" class="pdf-card grid grid-cols-4 gap-2">
      <.since_card
        icon="hero-scale"
        label="Weight"
        value={measurement_value(@latest_weight, :weight_g, :weight, @unit_system)}
        sub={measurement_date(@latest_weight, @child)}
        badge={@weight_percentile}
        badge_label={@weight_percentile && "percentile"}
        badge_id="pdf-weight-percentile"
      />
      <.since_card
        icon="hero-arrows-up-down"
        label="Height"
        value={measurement_value(@latest_height, :height_cm, :length, @unit_system)}
        sub={measurement_date(@latest_height, @child)}
        badge={@height_percentile}
        badge_label={@height_percentile && "percentile"}
        badge_id="pdf-height-percentile"
      />
      <.since_card
        icon="hero-clock"
        label="Total sleep / day"
        value={format_duration(@summary.totals.total.median)}
        sub={longest_night_sub(@summary.longest_night)}
      />
      <.since_card
        icon="hero-sparkles"
        label="Night stretch"
        value={format_duration(overnight_median(@summary))}
        sub={night_waking_sub(@summary.night_wakings)}
      />
      <.since_card
        icon="hero-sun"
        label="Morning wake"
        value={@summary.morning_wake.median_label || "—"}
        sub={@summary.morning_wake.consistency_label}
      />
      <.since_card
        icon="hero-moon"
        label="Bedtime"
        value={@summary.bedtime.median_label || "—"}
        sub={@summary.bedtime.consistency_label}
      />
      <.since_card
        icon="hero-beaker"
        label="Feeds / day"
        value={count_label(@feeding.count)}
        sub={volume_sub(@feeding, @unit_system)}
      />
      <.since_card
        icon="hero-fire"
        label="Est. calories / day"
        value={@kcal_label || "—"}
        sub="from bottle volume"
      />
    </section>
    """
  end

  ## Growth --------------------------------------------------------------------

  attr :child, Child, required: true
  attr :unit_system, :atom, required: true
  attr :weight_chart, :map, required: true
  attr :height_chart, :map, required: true
  attr :velocity, :map, required: true
  attr :measurements, :list, required: true
  attr :growth_label, :string, required: true
  attr :percentile_note, :string, default: nil

  defp growth_section(assigns) do
    ~H"""
    <section id="pdf-growth" class="space-y-3">
      <.section_title title="Growth" hint={@growth_label} />

      <div class="pdf-card grid grid-cols-2 gap-3">
        <div class="rounded-box border border-base-300 overflow-hidden">
          <.trend_chart
            id="pdf-growth-weight"
            kind="weight"
            title="Weight"
            unit={Units.unit_label(:weight, @unit_system)}
            chart={@weight_chart}
            static
          />
        </div>
        <div class="rounded-box border border-base-300 overflow-hidden">
          <.trend_chart
            id="pdf-growth-height"
            kind="height"
            title="Height"
            unit={Units.unit_label(:length, @unit_system)}
            chart={@height_chart}
            static
          />
        </div>
      </div>

      <div
        :if={@velocity.available? or @velocity.newborn}
        id="pdf-weight-gain"
        class="pdf-card rounded-box border border-base-300 p-3 text-sm space-y-1"
      >
        <h3 class="font-semibold text-sm">Weight gain</h3>
        <p :if={@velocity.available?}>
          <span class="font-semibold tabular-nums">
            {gain_label(@velocity.velocity.g_per_week, @unit_system)}/week
          </span>
          <span class="opacity-70">
            over {@velocity.velocity.days} days ({Calendar.strftime(@velocity.prior.date, "%-d %b")} → {Calendar.strftime(
              @velocity.latest.date,
              "%-d %b"
            )})
          </span>
        </p>
        <p :if={@velocity.available? and @velocity.velocity.percentile_now} class="opacity-80">
          Percentile {Percentiles.format_percentile(@velocity.velocity.percentile_prev)} →
          <span class="font-medium">
            {Percentiles.format_percentile(@velocity.velocity.percentile_now)}
          </span>
          <span :if={@velocity.velocity.percentile_drop?} class="text-warning">
            · crossed a major band
          </span>
        </p>
        <p
          :if={
            @velocity.available? and !@velocity.velocity.percentile_now and
              @velocity.velocity.guide_g_per_day
          }
          class="opacity-80"
        >
          {guide_copy(@velocity.velocity, @unit_system)}
        </p>
        <p :if={@velocity.newborn} class="opacity-80">
          {newborn_copy(@velocity.newborn, @unit_system)}
        </p>
      </div>

      <div id="pdf-measurements" class="pdf-card rounded-box border border-base-300 overflow-hidden">
        <div class="bg-base-200/40 px-3 py-2">
          <h3 class="font-semibold text-sm">Measurements</h3>
        </div>
        <p :if={@measurements == []} class="opacity-60 text-sm py-4 text-center">
          No height or weight logged yet.
        </p>
        <table :if={@measurements != []} class="table table-xs">
          <thead>
            <tr>
              <th>Date</th>
              <th>Age</th>
              <th>Weight</th>
              <th>Percentile</th>
              <th>Height</th>
              <th>Percentile</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={m <- @measurements} id={"pdf-measurement-#{m.id}"}>
              <td class="tabular-nums whitespace-nowrap">
                {Calendar.strftime(GrowthComponents.local_date(@child, m.measured_at), "%-d %b %Y")}
              </td>
              <td class="tabular-nums">
                {GrowthComponents.compact_age(
                  Child.age(@child, GrowthComponents.local_date(@child, m.measured_at))
                )}
              </td>
              <td class="tabular-nums">{Units.format(m.weight_g, :weight, @unit_system) || "—"}</td>
              <td class="tabular-nums opacity-70">
                {percentile_on(@child, :weight, m.weight_g, m.measured_at) || "—"}
              </td>
              <td class="tabular-nums">{Units.format(m.height_cm, :length, @unit_system) || "—"}</td>
              <td class="tabular-nums opacity-70">
                {percentile_on(@child, :length, m.height_cm, m.measured_at) || "—"}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  ## Sleep ---------------------------------------------------------------------

  attr :summary, :map, required: true
  attr :child, Child, required: true
  attr :export, :map, required: true

  defp sleep_section(assigns) do
    ~H"""
    <section id="pdf-sleep" class="space-y-3">
      <.section_title title="Sleep" hint="Per day, with the 7-day rolling total" />

      <p :if={!@summary.ready?} id="pdf-sleep-sparse" class="opacity-60 text-sm">
        Fewer than {@summary.min_sample} days of sleep logged in this window — trends are thin.
      </p>

      <div class="pdf-card grid grid-cols-2 gap-3">
        <.card id="pdf-sleep-trend" title="Sleep and awake time">
          <.sleep_bar_chart
            id="pdf-sleep-bars"
            series={@summary.totals.per_day}
            slope_label={@summary.totals.slope && slope_copy(@summary.totals.slope)}
            static
          />
        </.card>
        <.card id="pdf-clock-chart" title="Morning wake and bedtime">
          <.clock_chart id="pdf-clock" series={@summary.totals.per_day} />
        </.card>
      </div>

      <div class="pdf-card grid grid-cols-2 gap-3">
        <.card id="pdf-week" title="Last 7 days" hint="Sleep blocks, feeds and diapers by hour">
          <.week_calendar
            id="pdf-week-calendar"
            days={@export.week}
            child={@child}
            today_date={@export.today}
            static
          />
        </.card>
        <.card id="pdf-typical-day" title="Typical day" hint="How often they're asleep, by half hour">
          <.heat_strip
            id="pdf-heat"
            heatmap={@summary.heatmap}
            child={@child}
            morning_wake={@summary.morning_wake}
            bedtime={@summary.bedtime}
            static
          />
        </.card>
      </div>

      <div class="pdf-card grid grid-cols-2 gap-3 items-start">
        <.stat_table
          id="pdf-wake-windows"
          title="Wake windows"
          hint="Time up before the next sleep"
          empty="No completed wake windows yet."
          rows={@summary.wake_windows.by_ordinal}
          label_fn={&wake_window_label/1}
        />
        <.stat_table
          id="pdf-naps"
          title="Naps"
          hint="How long each nap typically lasts"
          empty="No naps logged yet."
          rows={@summary.naps.by_ordinal}
          label_fn={&"Nap #{ordinal(&1.ordinal)}"}
        />
      </div>
    </section>
    """
  end

  ## Feeding -------------------------------------------------------------------

  attr :feeding, :map, required: true
  attr :unit_system, :atom, required: true

  defp feeding_section(assigns) do
    units = assigns.unit_system
    per_day = assigns.feeding.per_day
    median_ml = assigns.feeding.ml.median

    assigns =
      assigns
      |> assign(:volume_series, Enum.map(per_day, &%{date: &1.date, value: &1.ml}))
      |> assign(:count_series, Enum.map(per_day, &%{date: &1.date, value: &1.count}))
      |> assign(
        :kcal_series,
        Enum.map(per_day, &%{date: &1.date, value: Norms.estimated_kcal(&1.ml)})
      )
      |> assign(:kcal_baseline, median_ml && Norms.estimated_kcal(median_ml))
      |> assign(:axis_volume, fn ml -> axis_volume(ml, units) end)
      |> assign(:axis_kcal, fn kcal -> to_string(round(kcal)) end)
      |> assign(:unit, Units.unit_label(:volume, units))

    ~H"""
    <section id="pdf-feeding" class="space-y-3">
      <.section_title title="Feeding" hint="Bottle volume, feed count and estimated calories per day" />

      <p :if={!@feeding.ready?} id="pdf-feeding-sparse" class="opacity-60 text-sm">
        Only a few bottles logged in this window — the rhythm figures are provisional.
      </p>

      <div class="pdf-card grid grid-cols-4 gap-2 text-center text-sm">
        <.stat id="pdf-feeding-per-day" value={count_label(@feeding.count)} label="feeds / day" />
        <.stat
          id="pdf-feeding-volume-day"
          value={
            (@feeding.ml.median && Units.format(@feeding.ml.median, :volume, @unit_system)) || "—"
          }
          label="volume / day"
        />
        <.stat
          id="pdf-feeding-day-interval"
          value={interval_label(@feeding.intervals.day)}
          label="between feeds by day"
        />
        <.stat
          id="pdf-feeding-night-interval"
          value={interval_label(@feeding.intervals.night)}
          label="between feeds by night"
        />
      </div>

      <div class="pdf-card grid grid-cols-2 gap-3">
        <.card id="pdf-feeding-volume" title={"Bottle volume per day (#{@unit})"}>
          <.count_bar_chart
            id="pdf-feeding-volume-chart"
            series={@volume_series}
            baseline={@feeding.ml.median}
            baseline_label={
              @feeding.ml.median &&
                "usual #{Units.format(@feeding.ml.median, :volume, @unit_system)} a day"
            }
            format={@axis_volume}
            label={"Bottle volume per day in #{@unit}"}
            highlight_last={false}
          />
        </.card>
        <.card id="pdf-feeding-kcal" title="Estimated calories per day (kcal)">
          <.count_bar_chart
            id="pdf-feeding-kcal-chart"
            series={@kcal_series}
            baseline={@kcal_baseline}
            baseline_label={@kcal_baseline && "usual ~#{round(@kcal_baseline)} kcal a day"}
            format={@axis_kcal}
            label="Estimated kilocalories per day"
            highlight_last={false}
          />
        </.card>
      </div>

      <div class="pdf-card grid grid-cols-2 gap-3">
        <.card id="pdf-feeding-count" title="Feeds per day">
          <.count_bar_chart
            id="pdf-feeding-count-chart"
            series={@count_series}
            baseline={@feeding.count.median}
            baseline_label={@feeding.count.median && "usual ~#{round(@feeding.count.median)} a day"}
            label="Feeds per day"
            highlight_last={false}
          />
        </.card>
        <div class="rounded-box border border-base-300 p-3 text-sm space-y-2">
          <h3 class="font-semibold text-sm">Intake</h3>
          <p :if={@feeding.intake} id="pdf-feeding-intake" class="opacity-80 leading-snug">
            Averaging {Units.format(@feeding.intake.avg_ml, :volume, @unit_system)} a day
            ({Units.format_rate_per_kg(@feeding.intake.ml_per_kg, @unit_system)} at {Units.format(
              @feeding.intake.weight_g,
              :weight,
              @unit_system
            )}) — {intake_status_copy(@feeding.intake, @unit_system)}
          </p>
          <p :if={!@feeding.intake} class="opacity-60">
            Log a recent weight to compare intake against the {Units.rate_per_kg_label(@unit_system)} guide for their age.
          </p>
          <p class="opacity-60 text-xs leading-snug">{Norms.kcal_note()}</p>
        </div>
      </div>
    </section>
    """
  end

  ## Diapers -------------------------------------------------------------------

  attr :diapers, :map, required: true

  defp diapers_section(assigns) do
    series = Enum.map(assigns.diapers.per_day, &%{date: &1.date, value: &1.wet})
    assigns = assign(assigns, :series, series)

    ~H"""
    <section id="pdf-diapers" class="space-y-3">
      <.section_title title="Diapers" hint="Wet diapers per day against their usual" />
      <div class="pdf-card grid grid-cols-2 gap-3">
        <.card id="pdf-diapers-wet" title="Wet diapers per day">
          <.count_bar_chart
            id="pdf-diapers-wet-chart"
            series={@series}
            baseline={@diapers.baseline.wet.median}
            baseline_label={
              @diapers.baseline.wet.median &&
                "usual ~#{round(@diapers.baseline.wet.median)} wet a day"
            }
            label="Wet diapers per day"
            highlight_last={false}
          />
        </.card>
        <div class="grid grid-cols-2 gap-2 content-start text-center text-sm">
          <.stat
            id="pdf-diapers-wet-usual"
            value={count_label(@diapers.baseline.wet)}
            label="wet / day"
          />
          <.stat
            id="pdf-diapers-dirty-usual"
            value={count_label(@diapers.baseline.dirty)}
            label="dirty / day"
          />
          <p class="col-span-2 text-left text-xs opacity-60 leading-snug">
            Guidance floor: at least {@diapers.min_wet} wet diapers a day and no more than {div(
              @diapers.max_dry_seconds,
              3600
            )} hours without one (AAP).
          </p>
        </div>
      </div>
    </section>
    """
  end

  ## Changes -------------------------------------------------------------------

  attr :shifts, :map, required: true

  defp changes_section(assigns) do
    findings = assigns.shifts.sleep ++ assigns.shifts.feeding
    assigns = assign(assigns, :findings, findings)

    ~H"""
    <section
      :if={@shifts.ready? and (@findings != [] or @shifts.growth_burst.active?)}
      id="pdf-changes"
      class="pdf-card rounded-box border border-base-300 overflow-hidden"
    >
      <div class="bg-base-200/40 px-3 py-2">
        <h3 class="font-semibold text-sm">Recent changes</h3>
        <p class="text-xs opacity-60">The last 3 days against the two weeks before</p>
      </div>
      <div class="p-3 text-sm space-y-1.5">
        <ul :if={@findings != []} class="space-y-1">
          <li :for={f <- @findings} id={"pdf-change-#{f.metric}"}>
            <span class="font-medium">{Shifts.metric_label(f.metric)}</span>
            <span class="opacity-70">
              {if f.direction == :up, do: "↑", else: "↓"} {finding_values(f)}
            </span>
          </li>
        </ul>
        <p :if={@shifts.growth_burst.active?} class="text-xs opacity-70 leading-snug">
          Sleeping noticeably more than usual on {Calendar.strftime(
            @shifts.growth_burst.on,
            "%a %-d %b"
          )} — in Lampl &amp; Johnson's 2011 diary study, bursts like this preceded a length spurt
          by 0–4 days.
        </p>
      </div>
    </section>
    """
  end

  ## Building blocks -----------------------------------------------------------

  attr :title, :string, required: true
  attr :hint, :string, default: nil

  defp section_title(assigns) do
    ~H"""
    <div class="pdf-title flex items-baseline justify-between gap-3 border-b border-base-300 pb-1">
      <h2 class="text-base font-bold">{@title}</h2>
      <p :if={@hint} class="text-xs opacity-60">{@hint}</p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :hint, :string, default: nil
  slot :inner_block, required: true

  defp card(assigns) do
    ~H"""
    <div id={@id} class="rounded-box border border-base-300 overflow-hidden">
      <div class="bg-base-200/40 px-3 py-2">
        <h3 class="font-semibold text-sm">{@title}</h3>
        <p :if={@hint} class="text-xs opacity-60">{@hint}</p>
      </div>
      <div class="p-3">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true

  defp stat(assigns) do
    ~H"""
    <div id={@id} class="rounded-box bg-base-200 border border-base-300 py-2 px-1">
      <div class="font-semibold tabular-nums">{@value}</div>
      <div class="opacity-60 text-xs">{@label}</div>
    </div>
    """
  end

  ## Helpers -------------------------------------------------------------------

  defp series_label([]), do: nil

  defp series_label(series) do
    from = hd(series).date
    to = List.last(series).date

    if Date.compare(from, to) == :eq do
      Calendar.strftime(to, "%-d %b %Y")
    else
      "#{Calendar.strftime(from, "%-d %b")} – #{Calendar.strftime(to, "%-d %b %Y")}"
    end
  end

  defp window_name(:all), do: "All logged days"
  defp window_name(n) when is_integer(n), do: "Last #{n} days"
  defp window_name(_), do: nil

  defp age_label(nil), do: nil
  defp age_label({0, 0, d}), do: "#{d} #{plural(d, "day")} old"
  defp age_label({0, m, 0}), do: "#{m} #{plural(m, "month")} old"
  defp age_label({0, m, d}), do: "#{m} #{plural(m, "month")}, #{d} #{plural(d, "day")} old"
  defp age_label({y, 0, _d}), do: "#{y} #{plural(y, "year")} old"
  defp age_label({y, m, _d}), do: "#{y} #{plural(y, "year")}, #{m} #{plural(m, "month")} old"

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  defp sex_label(:female), do: "Girl"
  defp sex_label(:male), do: "Boy"
  defp sex_label(_), do: nil

  defp measurement_value(nil, _field, _kind, _units), do: "—"

  defp measurement_value(measurement, field, kind, units) do
    Units.format(Map.get(measurement, field), kind, units) || "—"
  end

  defp measurement_date(nil, _child), do: "Not logged yet"

  defp measurement_date(measurement, child) do
    child
    |> GrowthComponents.local_date(measurement.measured_at)
    |> Calendar.strftime("%-d %b %Y")
  end

  defp measurement_percentile(nil, _field, _child), do: nil

  defp measurement_percentile(measurement, field, child) do
    kind = if field == :weight_g, do: :weight, else: :length
    percentile_on(child, kind, Map.get(measurement, field), measurement.measured_at)
  end

  defp percentile_on(_child, _kind, nil, _at), do: nil

  defp percentile_on(child, kind, value, %DateTime{} = at) do
    date = GrowthComponents.local_date(child, at)

    child
    |> Percentiles.percentile(kind, value, date)
    |> Percentiles.format_percentile()
  end

  defp overnight_median(%{totals: %{overnight: %{median: med}}}), do: med
  defp overnight_median(_), do: nil

  defp longest_night_sub(nil), do: nil

  defp longest_night_sub(%{date: date, seconds: seconds}) do
    "Longest night #{format_duration(seconds)} · #{Calendar.strftime(date, "%-d %b")}"
  end

  defp night_waking_sub(%{count: %{median: nil}}), do: nil

  defp night_waking_sub(%{count: %{median: n}}) do
    count = round(n)
    if count == 1, do: "~1 waking", else: "~#{count} wakings"
  end

  defp night_waking_sub(_), do: nil

  defp volume_sub(%{ml: %{median: nil}}, _units), do: nil

  defp volume_sub(%{ml: %{median: ml}}, units),
    do: "#{Units.format(ml, :volume, units)} a day"

  defp count_label(%{median: nil}), do: "—"
  defp count_label(%{median: med}), do: "~#{round(med)}"

  defp interval_label(%{median: nil}), do: "—"
  defp interval_label(%{median: med}), do: "~#{format_duration(med)}"

  defp axis_volume(ml, units) do
    case Units.to_display(ml, :volume, units) do
      nil -> ""
      v -> v |> Float.round(0) |> trunc() |> to_string()
    end
  end

  defp intake_status_copy(%{status: :within} = intake, units),
    do: "within the #{Units.format_rate_per_kg_range(intake.guide_per_kg, units)} guide for their age."

  defp intake_status_copy(%{status: :below} = intake, units),
    do:
      "below the #{Units.format_rate_per_kg_range(intake.guide_per_kg, units)} guide for their age. Babies vary; steady weight gain is the better check."

  defp intake_status_copy(%{status: :above} = intake, units),
    do:
      "above the #{Units.format_rate_per_kg_range(intake.guide_per_kg, units)} guide for their age. Follow their cues; the guide is only a guide."

  defp slope_copy(%{label: "steady"}), do: "Holding steady"
  defp slope_copy(%{label: label}), do: "Trend #{label}"

  defp ordinal(1), do: "1st"
  defp ordinal(2), do: "2nd"
  defp ordinal(3), do: "3rd"
  defp ordinal(n), do: "#{n}th"

  defp wake_window_label(%{ordinal: 1}), do: "After morning"
  defp wake_window_label(%{ordinal: n}), do: "After nap #{n - 1}"

  defp finding_values(f) do
    if Shifts.duration_metric?(f.metric) do
      "#{format_duration(f.recent_median)} vs usual #{format_duration(f.baseline_median)}"
    else
      "~#{trim_num(f.recent_median)} vs usual ~#{trim_num(f.baseline_median)}"
    end
  end

  defp trim_num(n) when is_float(n) do
    if n == Float.round(n), do: trunc(n), else: Float.round(n, 1)
  end

  defp trim_num(n), do: n

  defp gain_label(grams, :imperial) do
    oz = grams / 28.349523125
    "#{sign(oz)}#{:erlang.float_to_binary(abs(oz) * 1.0, decimals: 1)} oz"
  end

  defp gain_label(grams, _metric), do: "#{sign(grams)}#{round(abs(grams))} g"

  defp sign(n) when n < 0, do: "−"
  defp sign(_n), do: "+"

  defp guide_copy(%{guide_g_per_day: {lo, hi}, g_per_day: rate, guide_status: status}, units) do
    base =
      "About #{weight_rate_label(rate, units)} a day; typical for their age is " <>
        "#{weight_rate_label(lo, units)}–#{weight_rate_label(hi, units)} a day"

    case status do
      :below -> base <> " — a bit under, worth mentioning at the next visit."
      :above -> base <> " — a bit over, which is common and usually fine."
      _ -> base <> "."
    end
  end

  defp weight_rate_label(grams, :imperial) do
    oz = grams / 28.349523125
    "#{:erlang.float_to_binary(oz * 1.0, decimals: 1)} oz"
  end

  defp weight_rate_label(grams, _metric), do: "#{round(grams)} g"

  defp newborn_copy(newborn, units) do
    birth = Units.format(newborn.birth_grams, :weight, units)

    dip =
      if is_number(newborn.loss_pct) and newborn.loss_pct > 0 do
        " · lowest −#{Float.round(newborn.loss_pct, 1)}%"
      else
        ""
      end

    regain =
      cond do
        newborn.regained_day -> " · back to birth weight on day #{newborn.regained_day}"
        newborn.regain_overdue? -> " · not back to birth weight yet"
        true -> ""
      end

    "Born #{birth}#{dip}#{regain}."
  end
end
