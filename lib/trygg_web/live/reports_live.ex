defmodule TryggWeb.ReportsLive do
  use TryggWeb, :live_view

  alias Trygg.Accounts.Scope
  alias Trygg.Families
  alias Trygg.Families.Child
  alias Trygg.Reports
  alias Trygg.Reports.Day
  alias Trygg.Reports.Shifts
  alias Trygg.Units

  @tick_ms 60_000

  @windows [
    {7, "7d"},
    {14, "14d"},
    {30, "30d"},
    {90, "90d"},
    {:all, "All"}
  ]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_child={@current_child}
      children={@children}
      child_switch_to={:reports}
      title="Reports"
      back={~p"/c/#{@current_child}"}
    >
      <div id="report-view" class="grid grid-cols-3 gap-1.5">
        <.button
          :for={{id, label} <- [trends: "Trends", today: "Today", week: "7 days"]}
          id={"view-#{id}"}
          type="button"
          variant={if @view == id, do: "primary", else: "outline"}
          size="sm"
          phx-click="set_view"
          phx-value-view={id}
          class="min-h-11"
        >
          {label}
        </.button>
      </div>

      <.button
        id="download-pdf"
        href={~p"/c/#{@current_child}/reports.pdf?#{[window: @window]}"}
        download
        phx-hook="DownloadPdf"
        aria-busy="false"
        variant="outline"
        size="sm"
        class="group w-full min-h-11 mt-3 aria-busy:pointer-events-none aria-busy:opacity-70"
      >
        <.icon name="hero-arrow-down-tray" class="size-5 group-aria-busy:hidden" />
        <span class="loading loading-spinner loading-sm hidden group-aria-busy:inline-block"></span>
        <span class="group-aria-busy:hidden">Download PDF report</span>
        <span class="hidden group-aria-busy:inline">Preparing PDF…</span>
      </.button>

      <div
        id="day-night-def"
        class="mt-3 flex items-center justify-between gap-2 rounded-box border border-base-300 bg-base-200/40 px-3 py-2"
      >
        <p class="text-sm">
          <span class="opacity-60">Day</span>
          <span class="font-semibold tabular-nums">
            {Child.format_clock(@current_child.day_start)} – {Child.format_clock(
              @current_child.night_start
            )}
          </span>
        </p>
        <.button
          :if={@can_edit_schedule}
          id="change-day-night"
          type="button"
          variant="ghost"
          size="sm"
          phx-click="open_sheet"
        >
          Change
        </.button>
      </div>

      <.today_view
        :if={@view == :today}
        day={@day}
        child={@current_child}
        selected={@selected}
        caption={@caption}
        unit_system={@unit_system}
        today_date={@today_date}
      />
      <.week_view :if={@view == :week} days={@days} child={@current_child} today_date={@today_date} />
      <.trends_view
        :if={@view == :trends}
        insights={@insights}
        child={@current_child}
        unit_system={@unit_system}
        window={@window}
        window_label={@window_label}
        bar_selected={@bar_selected}
        bar_caption={@bar_caption}
        heat_selected={@heat_selected}
        heat_caption={@heat_caption}
      />

      <.sheet :if={@sheet} form={@form} />
    </Layouts.app>
    """
  end

  attr :day, Day, required: true
  attr :child, Child, required: true
  attr :selected, :any, default: nil
  attr :caption, :string, default: nil
  attr :unit_system, :atom, required: true
  attr :today_date, Date, required: true

  defp today_view(assigns) do
    ~H"""
    <section id="report-today" class="mt-4">
      <div class="flex items-center justify-between gap-2 mb-2">
        <.button
          id="day-prev"
          type="button"
          variant="outline"
          size="sm"
          phx-click="shift_day"
          phx-value-by="-1"
          class="min-h-11 min-w-11 px-0"
          aria-label="Previous day"
        >
          <.icon name="hero-chevron-left" class="size-5" />
        </.button>
        <h2 class="font-semibold tabular-nums text-center">
          {day_heading(@day.date, @today_date)}
        </h2>
        <.button
          id="day-next"
          type="button"
          variant="outline"
          size="sm"
          phx-click="shift_day"
          phx-value-by="1"
          disabled={Date.compare(@day.date, @today_date) != :lt}
          class="min-h-11 min-w-11 px-0"
          aria-label="Next day"
        >
          <.icon name="hero-chevron-right" class="size-5" />
        </.button>
      </div>

      <.today_calendar
        id="today-calendar"
        day={@day}
        child={@child}
        selected={@selected}
        unit_system={@unit_system}
      />

      <p
        id="today-caption"
        class={[
          "text-sm text-center mt-2 tabular-nums min-h-5",
          @caption && "font-medium",
          !@caption && "opacity-50 text-xs"
        ]}
      >
        {@caption || "Tap a block for details"}
      </p>

      <div class="grid grid-cols-2 gap-2 mt-4">
        <.since_card
          icon="hero-moon"
          label="Sleep"
          value={format_duration(@day.total_sleep_seconds)}
          sub={"Day #{format_duration(@day.day_sleep_seconds)} · Night #{format_duration(@day.night_sleep_seconds)}"}
        />
        <.since_card
          icon="hero-beaker"
          label="Feeds"
          value={to_string(length(@day.feeds))}
          sub={day_feed_sub(@day, @unit_system)}
        />
      </div>
    </section>
    """
  end

  # "620 ml · every ~2h 50m · 6 diapers" for the Today card.
  defp day_feed_sub(%Day{} = day, units) do
    ml = day.feeds |> Enum.map(&(&1.data["amount_ml"] || 0)) |> Enum.sum()

    interval =
      day.feeds
      |> Enum.map(& &1.at)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> DateTime.diff(b, a, :second) end)
      |> Enum.filter(&(&1 >= 30 * 60))
      |> Trygg.Reports.Stats.median()

    [
      if(ml > 0, do: Units.format(ml, :volume, units)),
      if(interval, do: "every ~#{format_duration(interval)}"),
      "#{length(day.diapers)} diapers"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  attr :days, :list, required: true
  attr :child, Child, required: true
  attr :today_date, Date, required: true

  defp week_view(assigns) do
    ~H"""
    <section id="report-week" class="mt-4">
      <h2 class="font-semibold mb-2">Last 7 days</h2>
      <.week_calendar id="week-calendar" days={@days} child={@child} today_date={@today_date} />
      <p class="text-xs opacity-50 text-center mt-2">Tap a day to open it</p>
    </section>
    """
  end

  attr :insights, :map, required: true
  attr :child, Child, required: true
  attr :unit_system, :atom, required: true
  attr :window, :any, required: true
  attr :window_label, :string, default: nil
  attr :bar_selected, :string, default: nil
  attr :bar_caption, :string, default: nil
  attr :heat_selected, :string, default: nil
  attr :heat_caption, :string, default: nil

  defp trends_view(assigns) do
    assigns = assign(assigns, :windows, windows())

    ~H"""
    <section id="report-trends" class="mt-4 space-y-4">
      <p :if={!@insights.ready?} id="trends-sparse" class="opacity-60 text-sm text-center py-2">
        Keep logging — insights appear after {@insights.min_sample} days.
      </p>

      <div class="grid grid-cols-2 gap-2">
        <.since_card
          icon="hero-sun"
          label="Morning wake"
          value={@insights.morning_wake.median_label || "—"}
          sub={@insights.morning_wake.consistency_label}
        />
        <.since_card
          icon="hero-moon"
          label="Bedtime"
          value={@insights.bedtime.median_label || "—"}
          sub={@insights.bedtime.consistency_label}
        />
        <.since_card
          icon="hero-clock"
          label="Total sleep"
          value={format_duration(@insights.totals.total.median)}
          sub={longest_night_sub(@insights.longest_night)}
        />
        <.since_card
          icon="hero-sparkles"
          label="Night stretch"
          value={format_duration(overnight_median(@insights))}
          sub={night_waking_sub(@insights.night_wakings)}
        />
      </div>

      <div id="todays-outlook" class="rounded-box border border-base-300 p-3">
        <h3 class="font-semibold text-sm mb-2">Today's outlook</h3>
        <.outlook prediction={@insights.prediction} next_feed={@insights.feeding.next_feed} />
      </div>

      <.alerts_list
        id="trend-alerts"
        title="Worth a look"
        alerts={@insights.alerts}
        links={%{vitals: ~p"/c/#{@child}/vitals"}}
      />

      <.feeding_card feeding={@insights.feeding} unit_system={@unit_system} />
      <.diapers_card diapers={@insights.diapers} />
      <.changes_card shifts={@insights.shifts} />

      <div id="sleep-trend-card" class="rounded-box border border-base-300 overflow-hidden">
        <div class="bg-base-200/40 px-3 pt-3 pb-2 space-y-2">
          <div class="flex items-start justify-between gap-2">
            <div class="min-w-0">
              <h3 class="font-semibold text-sm">Sleep trend</h3>
              <p id="trend-window" class="text-xs opacity-60 tabular-nums mt-0.5">
                {@window_label}
              </p>
            </div>
            <div class="flex gap-2 shrink-0">
              <.button
                id="trend-zoom-out"
                type="button"
                variant="outline"
                size="sm"
                phx-click="chart_zoom"
                phx-value-dir="out"
                disabled={@window == :all}
                aria-label="Zoom out"
                class="min-h-11 min-w-11 px-0"
              >
                <.icon name="hero-minus" class="size-5" />
              </.button>
              <.button
                id="trend-zoom-in"
                type="button"
                variant="outline"
                size="sm"
                phx-click="chart_zoom"
                phx-value-dir="in"
                disabled={@window == 7}
                aria-label="Zoom in"
                class="min-h-11 min-w-11 px-0"
              >
                <.icon name="hero-plus" class="size-5" />
              </.button>
            </div>
          </div>
          <div id="trend-range" class="grid grid-cols-5 gap-1.5">
            <.button
              :for={{id, label} <- @windows}
              id={"trend-period-#{id}"}
              type="button"
              variant={if @window == id, do: "primary", else: "outline"}
              size="sm"
              phx-click="set_window"
              phx-value-window={id}
              class="min-h-11 px-0"
            >
              {label}
            </.button>
          </div>
        </div>
        <div class="p-3">
          <.sleep_bar_chart
            id="sleep-trend"
            series={@insights.totals.per_day}
            slope_label={@insights.totals.slope && slope_copy(@insights.totals.slope)}
            selected={@bar_selected}
            caption={@bar_caption}
          />
        </div>
      </div>

      <div class="rounded-box border border-base-300 overflow-hidden">
        <div class="bg-base-200/40 px-3 py-2">
          <h3 class="font-semibold text-sm">Typical day</h3>
          <p class="text-xs opacity-60">When they're usually asleep over 24 hours</p>
        </div>
        <div class="p-3">
          <.heat_strip
            id="sleep-heat"
            heatmap={@insights.heatmap}
            child={@child}
            morning_wake={@insights.morning_wake}
            bedtime={@insights.bedtime}
            selected={@heat_selected}
            caption={@heat_caption}
          />
        </div>
      </div>

      <.stat_table
        id="wake-windows-table"
        title="Wake windows"
        hint="How long they're typically up before the next sleep"
        empty="No completed wake windows yet."
        rows={@insights.wake_windows.by_ordinal}
        label_fn={&wake_window_label/1}
      />
      <.stat_table
        id="naps-table"
        title="Naps"
        hint="How long each nap typically lasts"
        empty="No naps logged yet."
        rows={@insights.naps.by_ordinal}
        label_fn={&"Nap #{ordinal(&1.ordinal)}"}
      />
    </section>
    """
  end

  attr :prediction, :map, required: true
  attr :next_feed, :map, default: nil

  defp outlook(%{prediction: %{state: :asleep}} = assigns) do
    ~H"""
    <p id="outlook-asleep" class="text-sm font-medium">Asleep now</p>
    <p :if={@prediction.bedtime} class="text-sm opacity-70 mt-1">
      Typical bedtime {@prediction.bedtime.label}
    </p>
    <ul :if={@next_feed} class="text-sm mt-1">
      <.next_feed_line next_feed={@next_feed} />
    </ul>
    """
  end

  defp outlook(assigns) do
    ~H"""
    <ul class="text-sm space-y-1">
      <li :if={@prediction.morning_wake} id="outlook-wake">
        <span class="opacity-60">
          {if @prediction.morning_wake.actual?, do: "Woke", else: "Typical wake"}
        </span>
        <span class="font-semibold tabular-nums">{@prediction.morning_wake.label}</span>
      </li>
      <li :if={@prediction.next_nap} id="outlook-next-nap">
        <span class="opacity-60">Next nap ≈</span>
        <span class="font-semibold tabular-nums">{@prediction.next_nap.label}</span>
        <span :if={@prediction.next_nap.range} class="opacity-60 tabular-nums">
          ({@prediction.next_nap.range.label})
        </span>
        <span class="opacity-60">{"· " <> in_label(@prediction.next_nap.in_seconds)}</span>
        <span :if={@prediction.next_nap.source == :age_prior} class="opacity-60">
          · typical for age
        </span>
      </li>
      <li :if={@prediction.wake_pressure && @prediction.wake_pressure.state} id="outlook-awake">
        <span class="opacity-60">Awake</span>
        <span class="font-semibold tabular-nums">
          {format_duration(@prediction.wake_pressure.awake_seconds)}
        </span>
        <span class="opacity-60">
          · usually {format_duration(@prediction.wake_pressure.typical_seconds)}{pressure_note(
            @prediction.wake_pressure
          )}
        </span>
      </li>
      <li :if={@prediction.bedtime} id="outlook-bedtime">
        <span class="opacity-60">
          {if @prediction.bedtime.estimate?, do: "Bedtime ≈", else: "Bedtime"}
        </span>
        <span class="font-semibold tabular-nums">{@prediction.bedtime.label}</span>
      </li>
      <li :if={
        @prediction.morning_wake == nil and @prediction.next_nap == nil and @prediction.bedtime == nil
      }>
        <span class="opacity-60">Not enough sleep history to predict yet.</span>
      </li>
      <.next_feed_line next_feed={@next_feed} />
    </ul>
    <ul
      :if={@prediction.schedule != []}
      id="outlook-schedule"
      class="mt-2 text-xs opacity-70 space-y-0.5"
    >
      <li :for={item <- @prediction.schedule}>{item.label}</li>
    </ul>
    """
  end

  attr :next_feed, :map, default: nil

  defp next_feed_line(%{next_feed: nil} = assigns), do: ~H""

  defp next_feed_line(assigns) do
    ~H"""
    <li id="outlook-next-feed">
      <span class="opacity-60">Next feed ≈</span>
      <span class="font-semibold tabular-nums">{@next_feed.label}</span>
      <span :if={@next_feed.range} class="opacity-60 tabular-nums">({@next_feed.range.label})</span>
      <span class="opacity-60">{"· " <> in_label(@next_feed.in_seconds)}</span>
    </li>
    """
  end

  defp pressure_note(%{state: :past}), do: " · past their usual window"
  defp pressure_note(%{state: :approaching}), do: " · nap time is near"
  defp pressure_note(%{source: :age_prior}), do: " (for age)"
  defp pressure_note(_), do: ""

  ## Feeding card ---------------------------------------------------------

  attr :feeding, :map, required: true
  attr :unit_system, :atom, required: true

  defp feeding_card(assigns) do
    series = Enum.map(assigns.feeding.per_day, &%{date: &1.date, value: &1.ml})
    units = assigns.unit_system

    assigns =
      assigns
      |> assign(:series, series)
      |> assign(:axis_format, fn ml -> axis_volume(ml, units) end)
      |> assign(:unit, Units.unit_label(:volume, units))

    ~H"""
    <div id="trend-feeding" class="rounded-box border border-base-300 overflow-hidden">
      <div class="bg-base-200/40 px-3 py-2">
        <h3 class="font-semibold text-sm">Feeding</h3>
        <p class="text-xs opacity-60">Bottle volume per day and how far apart feeds fall</p>
      </div>
      <div class="p-3 space-y-3">
        <p :if={!@feeding.ready?} id="feeding-sparse" class="opacity-60 text-sm text-center py-2">
          Log a few more bottles and the rhythm will show up here.
        </p>
        <div
          :if={@feeding.ready?}
          class="grid grid-cols-2 sm:grid-cols-4 gap-2 text-center text-sm"
        >
          <div id="feeding-day-interval" class="rounded-box bg-base-200 border border-base-300 py-2">
            <div class="font-semibold tabular-nums">{interval_label(@feeding.intervals.day)}</div>
            <div class="opacity-60 text-xs">between feeds, day</div>
          </div>
          <div
            id="feeding-night-interval"
            class="rounded-box bg-base-200 border border-base-300 py-2"
          >
            <div class="font-semibold tabular-nums">{interval_label(@feeding.intervals.night)}</div>
            <div class="opacity-60 text-xs">between feeds, night</div>
          </div>
          <div id="feeding-per-day" class="rounded-box bg-base-200 border border-base-300 py-2">
            <div class="font-semibold tabular-nums">{count_label(@feeding.count)}</div>
            <div class="opacity-60 text-xs">feeds / day</div>
            <div :if={@feeding.typical} class="opacity-60 text-xs tabular-nums">
              typical {range_label(@feeding.typical.feeds_per_day)}
            </div>
          </div>
          <div id="feeding-per-feed" class="rounded-box bg-base-200 border border-base-300 py-2">
            <div class="font-semibold tabular-nums">
              {volume_label(@feeding.per_feed.median, @unit_system)}
            </div>
            <div class="opacity-60 text-xs">per feed</div>
            <div
              :if={@feeding.typical && @feeding.typical.ml_per_feed}
              class="opacity-60 text-xs tabular-nums"
            >
              typical {volume_range_label(@feeding.typical.ml_per_feed, @unit_system)}
            </div>
          </div>
        </div>
        <p :if={@feeding.typical} id="feeding-age-guide" class="text-xs opacity-70 leading-snug">
          <span class="font-medium">Typical for age:</span>
          {typical_feeds_copy(@feeding.typical, @unit_system)} Babies vary — feed on their cues, not
          the clock; wet diapers and steady weight gain are the real check.
        </p>
        <.count_bar_chart
          id="feeding-volume"
          series={@series}
          baseline={@feeding.ml.median}
          baseline_label={
            @feeding.ml.median &&
              "usual #{Units.format(@feeding.ml.median, :volume, @unit_system)} a day"
          }
          format={@axis_format}
          label={"Bottle volume per day in #{@unit}"}
        />
        <p :if={@feeding.intake} id="feeding-intake" class="text-xs opacity-70 leading-snug">
          <span class="font-medium">Intake guide:</span>
          averaging {Units.format(@feeding.intake.avg_ml, :volume, @unit_system)} a day
          ({round(@feeding.intake.ml_per_kg)} ml/kg at {Units.format(
            @feeding.intake.weight_g,
            :weight,
            @unit_system
          )}) — {intake_status_copy(@feeding.intake)}
        </p>
        <p :if={@feeding.cluster.active?} id="feeding-cluster" class="text-xs opacity-70">
          {@feeding.cluster.count} feeds in the last 2 hours — looks like cluster feeding, which is
          normal and often comes before a longer sleep stretch.
        </p>
      </div>
    </div>
    """
  end

  defp axis_volume(ml, units) do
    case Units.to_display(ml, :volume, units) do
      nil -> ""
      v -> v |> Float.round(0) |> trunc() |> to_string()
    end
  end

  defp interval_label(%{median: nil}), do: "—"
  defp interval_label(%{median: med}), do: "~#{format_duration(med)}"

  defp count_label(%{median: nil}), do: "—"
  defp count_label(%{median: med}), do: "~#{round(med)}"

  defp volume_label(nil, _units), do: "—"
  defp volume_label(ml, units), do: "~#{Units.format(ml, :volume, units)}"

  defp range_label({lo, hi}), do: "#{lo}–#{hi}"

  # "150–180 ml" / "5–6 oz": one unit suffix for the whole range.
  defp volume_range_label({lo, hi}, units) do
    "#{axis_volume(lo, units)}–#{axis_volume(hi, units)} #{Units.unit_label(:volume, units)}"
  end

  defp typical_feeds_copy(%{feeds_per_day: feeds, ml_per_feed: nil}, _units) do
    "about #{range_label(feeds)} feeds of formula or solids a day (CDC)."
  end

  defp typical_feeds_copy(%{feeds_per_day: feeds, ml_per_feed: ml}, units) do
    "about #{range_label(feeds)} feeds of #{volume_range_label(ml, units)} a day " <>
      "(Johns Hopkins / CDC)."
  end

  defp intake_status_copy(%{status: :within, guide_per_kg: {lo, hi}}),
    do: "within the #{lo}–#{hi} ml/kg guide for their age."

  defp intake_status_copy(%{status: :below, guide_per_kg: {lo, hi}}),
    do:
      "below the #{lo}–#{hi} ml/kg guide for their age. Babies vary; steady weight gain is the better check."

  defp intake_status_copy(%{status: :above, guide_per_kg: {lo, hi}}),
    do:
      "above the #{lo}–#{hi} ml/kg guide for their age. Follow their cues; the guide is only a guide."

  ## Diapers card ---------------------------------------------------------

  attr :diapers, :map, required: true

  defp diapers_card(assigns) do
    series = Enum.map(assigns.diapers.per_day, &%{date: &1.date, value: &1.wet})
    assigns = assign(assigns, :series, series)

    ~H"""
    <div id="trend-diapers" class="rounded-box border border-base-300 overflow-hidden">
      <div class="bg-base-200/40 px-3 py-2">
        <h3 class="font-semibold text-sm">Diapers</h3>
        <p class="text-xs opacity-60">Wet diapers per day against their usual</p>
      </div>
      <div class="p-3 space-y-3">
        <div class="grid grid-cols-3 gap-2 text-center text-sm">
          <div id="diapers-wet-usual" class="rounded-box bg-base-200 border border-base-300 py-2">
            <div class="font-semibold tabular-nums">{count_label(@diapers.baseline.wet)}</div>
            <div class="opacity-60 text-xs">wet / day</div>
          </div>
          <div id="diapers-dirty-usual" class="rounded-box bg-base-200 border border-base-300 py-2">
            <div class="font-semibold tabular-nums">{count_label(@diapers.baseline.dirty)}</div>
            <div class="opacity-60 text-xs">dirty / day</div>
          </div>
          <div id="diapers-today" class="rounded-box bg-base-200 border border-base-300 py-2">
            <div class="font-semibold tabular-nums">{today_wet_label(@diapers.today)}</div>
            <div class="opacity-60 text-xs">wet today</div>
          </div>
        </div>
        <.count_bar_chart
          id="diapers-wet"
          series={@series}
          baseline={@diapers.baseline.wet.median}
          baseline_label={
            @diapers.baseline.wet.median &&
              "usual ~#{round(@diapers.baseline.wet.median)} wet a day"
          }
          label="Wet diapers per day"
        />
        <p class="text-xs opacity-60 leading-snug">
          Guidance floor: at least {@diapers.min_wet} wet diapers a day and no more than {div(
            @diapers.max_dry_seconds,
            3600
          )} hours without one (AAP).
        </p>
      </div>
    </div>
    """
  end

  defp today_wet_label(nil), do: "—"

  defp today_wet_label(%{wet: wet, expected_wet_by_now: expected}) when is_number(expected),
    do: "#{wet} / ~#{round(expected)}"

  defp today_wet_label(%{wet: wet}), do: to_string(wet)

  ## Changes card ---------------------------------------------------------

  attr :shifts, :map, required: true

  defp changes_card(assigns) do
    findings = assigns.shifts.sleep ++ assigns.shifts.feeding
    assigns = assign(assigns, :findings, findings)

    ~H"""
    <div id="trend-changes" class="rounded-box border border-base-300 overflow-hidden">
      <div class="bg-base-200/40 px-3 py-2">
        <h3 class="font-semibold text-sm">Changes</h3>
        <p class="text-xs opacity-60">The last 3 days against the two weeks before</p>
      </div>
      <div class="p-3">
        <p :if={!@shifts.ready?} id="changes-sparse" class="opacity-60 text-sm text-center py-2">
          Needs about {@shifts.min_baseline + 3} days of sleep logs to compare against.
        </p>
        <p
          :if={@shifts.ready? and @findings == [] and !@shifts.growth_burst.active?}
          id="changes-none"
          class="opacity-60 text-sm text-center py-2"
        >
          No notable changes in the last 3 days.
        </p>
        <ul :if={@findings != []} id="changes-list" class="text-sm space-y-1.5">
          <li :for={f <- @findings} id={"change-#{f.metric}"} class="flex items-baseline gap-2">
            <.icon
              name={
                if f.direction == :up, do: "hero-arrow-trending-up", else: "hero-arrow-trending-down"
              }
              class="size-4 shrink-0 opacity-70"
            />
            <span>
              <span class="font-medium">{Shifts.metric_label(f.metric)}</span>
              <span class="opacity-70">{finding_values(f)}</span>
            </span>
          </li>
        </ul>
        <p
          :if={@shifts.ready? and @shifts.growth_burst.active?}
          id="changes-growth-burst"
          class="text-xs opacity-70 mt-2 leading-snug"
        >
          Sleeping noticeably more than usual on {Calendar.strftime(
            @shifts.growth_burst.on,
            "%a %-d %b"
          )} — in Lampl &amp; Johnson's 2011 diary study, bursts like this preceded a length
          spurt by 0–4 days.
        </p>
      </div>
    </div>
    """
  end

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

  attr :form, :any, required: true

  defp sheet(assigns) do
    ~H"""
    <div
      id="day-night-sheet"
      class="fixed inset-0 z-50 flex items-end sm:items-center justify-center"
      phx-window-keydown="close_sheet"
      phx-key="escape"
    >
      <div class="absolute inset-0 bg-black/60" phx-click="close_sheet"></div>
      <div class="relative w-full sm:max-w-md bg-base-100 border-t border-base-300 sm:border sm:rounded-box rounded-t-2xl p-5 pb-[calc(env(safe-area-inset-bottom)+1.25rem)] max-h-[90dvh] overflow-y-auto">
        <h3 class="font-semibold text-lg mb-3">Day and night</h3>
        <p class="text-sm opacity-60 mb-3">
          Used to split day vs night sleep and to shade the calendar.
        </p>
        <.form for={@form} id="day-night-form" phx-submit="save_schedule" class="space-y-3">
          <.input field={@form[:day_start]} type="time" label="Day starts" />
          <.input field={@form[:night_start]} type="time" label="Night starts" />
          <div class="flex gap-2 pt-2">
            <.button type="submit" variant="primary" size="lg" class="flex-1 min-h-12 text-base">
              Save
            </.button>
            <.button type="button" variant="ghost" size="lg" class="min-h-12" phx-click="close_sheet">
              Cancel
            </.button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  ## Lifecycle ------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :tick, @tick_ms)
      Trygg.Accounts.subscribe_user(socket.assigns.current_scope.user.id)
    end

    {:ok,
     socket
     |> assign(:unit_system, socket.assigns.current_scope.user.unit_system)
     |> assign(:can_write, socket.assigns.role in [:owner, :caregiver])
     |> assign(:can_edit_schedule, socket.assigns.role == :owner)
     |> assign(:sheet, false)
     |> assign(:form, nil)
     |> assign(:selected, nil)
     |> assign(:caption, nil)
     |> assign(:day, nil)
     |> assign(:days, nil)
     |> assign(:insights, nil)
     |> assign(:window_label, nil)
     |> assign(:bar_selected, nil)
     |> assign(:bar_caption, nil)
     |> assign(:heat_selected, nil)
     |> assign(:heat_caption, nil)
     |> assign(:now, DateTime.utc_now() |> DateTime.truncate(:second))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    child = socket.assigns.current_child
    today = Child.local_today(child)

    {:noreply,
     socket
     |> assign(:view, parse_view(params["view"], params["date"]))
     |> assign(:date, parse_date(params["date"], today))
     |> assign(:window, parse_window_param(params["window"], socket.assigns[:window]))
     |> assign(:today_date, today)
     |> assign(:selected, nil)
     |> assign(:caption, nil)
     |> assign(:bar_selected, nil)
     |> assign(:bar_caption, nil)
     |> assign(:heat_selected, nil)
     |> assign(:heat_caption, nil)
     |> load_report()}
  end

  @impl true
  def handle_info({:log, _action, _entry}, socket), do: {:noreply, load_report(socket)}

  def handle_info({:child_updated, child}, socket) do
    {:noreply,
     socket
     |> assign(:current_child, %{child | role: socket.assigns.role})
     |> load_report()}
  end

  def handle_info({:child_deleted, _child_id}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "#{socket.assigns.current_child.name} was deleted.")
     |> push_navigate(to: ~p"/")}
  end

  def handle_info({:members_changed, _child_id}, socket) do
    {:noreply, resync_membership(socket)}
  end

  def handle_info({:user_updated, user}, socket) do
    {:noreply,
     socket
     |> assign(:current_scope, %{socket.assigns.current_scope | user: user})
     |> assign(:unit_system, user.unit_system)
     |> load_report()}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)

    {:noreply,
     socket
     |> assign(:now, DateTime.utc_now() |> DateTime.truncate(:second))
     |> load_report()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp resync_membership(socket) do
    scope = socket.assigns.current_scope
    child = socket.assigns.current_child

    case Families.member_role(scope, child) do
      nil ->
        socket
        |> put_flash(:error, "You no longer have access to #{child.name}.")
        |> push_navigate(to: ~p"/")

      role ->
        child = %{child | role: role}

        socket
        |> assign(:role, role)
        |> assign(:can_write, role in [:owner, :caregiver])
        |> assign(:can_edit_schedule, role == :owner)
        |> assign(:current_child, child)
        |> assign(:current_scope, Scope.put_child(scope, child, role))
        |> load_report()
    end
  end

  ## Events ---------------------------------------------------------------

  @impl true
  def handle_event("set_view", %{"view" => view}, socket) do
    {:noreply, push_patch(socket, to: report_path(socket, view: parse_view(view)))}
  end

  def handle_event("set_window", %{"window" => window}, socket) do
    {:noreply, push_patch(socket, to: report_path(socket, window: parse_window(window)))}
  end

  # Sent by the DownloadPdf hook when the fetch for the PDF fails.
  def handle_event("pdf_failed", _params, socket) do
    {:noreply, put_flash(socket, :error, "Couldn't build the PDF right now — please try again.")}
  end

  def handle_event("chart_zoom", %{"dir" => dir}, socket) do
    window = zoom_window(socket.assigns.window, dir)
    {:noreply, push_patch(socket, to: report_path(socket, window: window))}
  end

  def handle_event("select_heat", %{"index" => index}, socket) do
    if socket.assigns.heat_selected == index do
      {:noreply, assign(socket, heat_selected: nil, heat_caption: nil)}
    else
      {:noreply,
       assign(socket,
         heat_selected: index,
         heat_caption: TryggWeb.ReportComponents.heat_bin_caption(socket.assigns.insights, index)
       )}
    end
  end

  def handle_event("select_bar", %{"date" => iso}, socket) do
    if socket.assigns.bar_selected == iso do
      today = socket.assigns.today_date
      date = parse_date(iso, today)
      {:noreply, push_patch(socket, to: report_path(socket, view: :today, date: date))}
    else
      point = find_bar(socket.assigns.insights, iso)

      {:noreply,
       assign(socket,
         bar_selected: iso,
         bar_caption: point && TryggWeb.ReportComponents.sleep_bar_caption(point)
       )}
    end
  end

  def handle_event("shift_day", %{"by" => by}, socket) do
    delta = String.to_integer(by)
    date = Date.add(socket.assigns.date, delta)
    today = socket.assigns.today_date
    date = if Date.after?(date, today), do: today, else: date
    {:noreply, push_patch(socket, to: report_path(socket, date: date))}
  end

  def handle_event("open_day", %{"date" => iso}, socket) do
    today = socket.assigns.today_date
    date = parse_date(iso, today)
    {:noreply, push_patch(socket, to: report_path(socket, view: :today, date: date))}
  end

  def handle_event("select_segment", %{"kind" => kind, "id" => id}, socket) do
    key = {kind, id}
    selected = if socket.assigns.selected == key, do: nil, else: key
    caption = caption_for(socket, selected)
    {:noreply, assign(socket, selected: selected, caption: caption)}
  end

  def handle_event("open_sheet", _params, socket) do
    if socket.assigns.can_edit_schedule do
      {:noreply,
       socket
       |> assign(:sheet, true)
       |> assign(:form, to_form(Families.change_child(socket.assigns.current_child)))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_sheet", _params, socket) do
    {:noreply, assign(socket, sheet: false, form: nil)}
  end

  def handle_event("save_schedule", %{"child" => params}, socket) do
    if socket.assigns.can_edit_schedule do
      attrs = Map.take(params, ["day_start", "night_start"])

      case Families.update_child(
             socket.assigns.current_scope,
             socket.assigns.current_child,
             attrs
           ) do
        {:ok, child} ->
          {:noreply,
           socket
           |> assign(:current_child, %{child | role: socket.assigns.role})
           |> assign(:sheet, false)
           |> assign(:form, nil)
           |> load_report()
           |> put_flash(:info, "Saved.")}

        {:error, changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, socket}
    end
  end

  ## Data -----------------------------------------------------------------

  defp load_report(socket) do
    scope = socket.assigns.current_scope
    child = socket.assigns.current_child
    now = socket.assigns.now

    case socket.assigns[:view] do
      :week ->
        today = Child.local_today(child)
        from = Date.add(today, -6)

        socket
        |> assign(:days, Reports.days(scope, child, from, today, now))
        |> assign(:day, nil)
        |> assign(:insights, nil)

      :trends ->
        insights = Reports.summary(scope, child, socket.assigns.window, now)

        socket
        |> assign(:insights, insights)
        |> assign(:window_label, window_label(insights.totals.per_day))
        |> assign(:day, nil)
        |> assign(:days, nil)

      _ ->
        date = socket.assigns[:date] || Child.local_today(child)

        socket
        |> assign(:day, Reports.day(scope, child, date, now))
        |> assign(:days, nil)
        |> assign(:insights, nil)
    end
  end

  defp caption_for(_socket, nil), do: nil

  defp caption_for(socket, {kind, id}) do
    TryggWeb.ReportComponents.segment_caption(
      socket.assigns.day,
      socket.assigns.current_child,
      {kind, id},
      socket.assigns.unit_system
    )
  end

  defp report_path(socket, opts) do
    child = socket.assigns.current_child
    view = Keyword.get(opts, :view, socket.assigns.view)
    date = Keyword.get(opts, :date, socket.assigns.date)
    window = Keyword.get(opts, :window, socket.assigns.window)

    query =
      case view do
        :today -> [view: "today", date: Date.to_iso8601(date)]
        :week -> [view: "week"]
        :trends -> [view: "trends", window: window]
      end

    ~p"/c/#{child}/reports?#{query}"
  end

  defp parse_view(value, date_param \\ nil)

  defp parse_view(value, _date) when value in ["today", :today], do: :today
  defp parse_view(value, _date) when value in ["week", :week], do: :week

  defp parse_view(value, _date) when value in ["trends", :trends, "summary", :summary],
    do: :trends

  defp parse_view(_value, date) when is_binary(date) and date != "", do: :today
  defp parse_view(_, _), do: :trends

  defp parse_window(value) when value in ["14", 14], do: 14
  defp parse_window(value) when value in ["30", 30], do: 30
  defp parse_window(value) when value in ["90", 90], do: 90
  defp parse_window(value) when value in ["all", :all], do: :all
  defp parse_window(_), do: 7

  defp parse_window_param(nil, current) when not is_nil(current), do: current
  defp parse_window_param(value, _current), do: parse_window(value)

  defp windows, do: @windows

  defp zoom_window(window, dir) do
    order = Enum.map(@windows, &elem(&1, 0))
    idx = Enum.find_index(order, &(&1 == window)) || 0

    case dir do
      "in" -> Enum.at(order, max(idx - 1, 0))
      _ -> Enum.at(order, min(idx + 1, length(order) - 1))
    end
  end

  defp find_bar(%{totals: %{per_day: series}}, iso) when is_list(series) do
    Enum.find(series, &(Date.to_iso8601(&1.date) == iso))
  end

  defp find_bar(_, _), do: nil

  defp window_label([]), do: nil

  defp window_label(series) do
    from = hd(series).date
    to = List.last(series).date

    if Date.compare(from, to) == :eq do
      Calendar.strftime(to, "%-d %b %Y")
    else
      "#{Calendar.strftime(from, "%-d %b")} – #{Calendar.strftime(to, "%-d %b %Y")}"
    end
  end

  defp parse_date(nil, today), do: today
  defp parse_date("", today), do: today

  defp parse_date(iso, today) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> if Date.after?(date, today), do: today, else: date
      _ -> today
    end
  end

  defp parse_date(%Date{} = date, today) do
    if Date.after?(date, today), do: today, else: date
  end

  defp parse_date(_, today), do: today

  defp day_heading(date, today) do
    cond do
      Date.compare(date, today) == :eq ->
        "Today · #{Calendar.strftime(date, "%a %-d %b")}"

      Date.compare(date, Date.add(today, -1)) == :eq ->
        "Yesterday · #{Calendar.strftime(date, "%a %-d %b")}"

      true ->
        Calendar.strftime(date, "%a %-d %b %Y")
    end
  end

  defp overnight_median(%{totals: %{overnight: %{median: med}}}), do: med
  defp overnight_median(_), do: nil

  defp longest_night_sub(nil), do: nil

  defp longest_night_sub(%{date: date, seconds: seconds}) do
    "Longest night #{format_duration(seconds)} · #{Calendar.strftime(date, "%-d %b")}"
  end

  defp night_waking_sub(%{count: %{median: nil}}), do: nil

  defp night_waking_sub(%{count: %{median: n}}) do
    count = n |> round()
    if count == 1, do: "~1 waking", else: "~#{count} wakings"
  end

  defp night_waking_sub(_), do: nil

  defp slope_copy(%{label: "steady"}), do: "Holding steady"
  defp slope_copy(%{label: label}), do: "Trend #{label}"

  defp ordinal(1), do: "1st"
  defp ordinal(2), do: "2nd"
  defp ordinal(3), do: "3rd"
  defp ordinal(n), do: "#{n}th"

  defp wake_window_label(%{ordinal: 1}), do: "After morning"
  defp wake_window_label(%{ordinal: n}), do: "After nap #{n - 1}"

  defp in_label(seconds) when is_integer(seconds) and seconds < -60,
    do: "#{format_duration(-seconds)} past usual"

  defp in_label(seconds) when is_integer(seconds) and seconds < 60, do: "about now"
  defp in_label(seconds) when is_integer(seconds), do: "in #{format_duration(seconds)}"
end
