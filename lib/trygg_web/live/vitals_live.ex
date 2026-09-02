defmodule TryggWeb.VitalsLive do
  use TryggWeb, :live_view

  alias Trygg.Accounts.Scope
  alias Trygg.Accounts.User
  alias Trygg.Families
  alias Trygg.Families.Child
  alias Trygg.Growth
  alias Trygg.Growth.Measurement
  alias Trygg.Growth.Percentiles
  alias Trygg.Growth.Velocity
  alias Trygg.Reports
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_child={@current_child}
      children={@children}
      child_switch_to={:vitals}
      title="Vitals"
      back={~p"/c/#{@current_child}"}
    >
      <section class="rounded-box border border-base-300 bg-base-200/40 p-2">
        <div class="grid grid-cols-2 gap-2">
          <div id="latest-weight">
            <.since_card
              icon="hero-scale"
              label="Weight"
              value={metric_value(@latest_weight, :weight_g, :weight, @unit_system)}
              sub={metric_sub(@latest_weight, @current_child)}
              badge={@weight_percentile}
              badge_label={@weight_percentile && "percentile"}
              badge_id="latest-weight-percentile"
            />
          </div>
          <div id="latest-height">
            <.since_card
              icon="hero-arrows-up-down"
              label="Height"
              value={metric_value(@latest_height, :height_cm, :length, @unit_system)}
              sub={metric_sub(@latest_height, @current_child)}
              badge={@height_percentile}
              badge_label={@height_percentile && "percentile"}
              badge_id="latest-height-percentile"
            />
          </div>
        </div>
      </section>

      <.weight_gain_card
        velocity={@velocity}
        growth_burst={@growth_burst}
        child={@current_child}
        unit_system={@unit_system}
        can_write={@can_write}
      />

      <.button
        :if={@can_write}
        id="add-measurement"
        type="button"
        variant="primary"
        size="lg"
        class="w-full mt-4 min-h-12 text-base"
        phx-click="open_sheet"
      >
        Log height and weight
      </.button>

      <section id="growth-charts" class="mt-6 rounded-box border border-base-300 overflow-hidden">
        <div class="bg-base-200/40 px-3 pt-3 pb-2 space-y-2">
          <div class="flex items-start justify-between gap-2">
            <div class="min-w-0">
              <h2 class="font-semibold">Growth</h2>
              <p id="chart-window" class="text-xs opacity-60 tabular-nums mt-0.5">
                {@chart_window_label}
              </p>
            </div>
            <div class="flex gap-2 shrink-0">
              <.button
                id="chart-zoom-out"
                type="button"
                variant="outline"
                size="sm"
                phx-click="chart_zoom"
                phx-value-dir="out"
                disabled={@chart_period == :all}
                aria-label="Zoom out"
                class="min-h-11 min-w-11 px-0"
              >
                <.icon name="hero-minus" class="size-5" />
              </.button>
              <.button
                id="chart-zoom-in"
                type="button"
                variant="outline"
                size="sm"
                phx-click="chart_zoom"
                phx-value-dir="in"
                disabled={@chart_period == :weeks_2}
                aria-label="Zoom in"
                class="min-h-11 min-w-11 px-0"
              >
                <.icon name="hero-plus" class="size-5" />
              </.button>
            </div>
          </div>
          <.chart_toolbar period={@chart_period} />
        </div>
        <div class="divide-y divide-base-300">
          <.trend_chart
            id="weight-chart"
            kind="weight"
            title="Weight"
            unit={Units.unit_label(:weight, @unit_system)}
            chart={@weight_chart}
          />
          <.trend_chart
            id="height-chart"
            kind="height"
            title="Height"
            unit={Units.unit_label(:length, @unit_system)}
            chart={@height_chart}
          />
        </div>
        <p
          :if={@percentile_note}
          id="percentile-source"
          class="text-xs opacity-50 px-3 py-2 border-t border-base-300"
        >
          {@percentile_note} · 5th–95th
        </p>
        <p
          :if={@percentile_hint == :unspecified_sex}
          id="percentile-hint"
          class="text-xs opacity-60 px-3 py-2 border-t border-base-300"
        >
          Set this child's sex to girl or boy to see CDC growth percentiles.
          <.link navigate={~p"/children/#{@current_child}/edit"} class="underline">Edit child</.link>
        </p>
        <p
          :if={@percentile_hint == :no_birth_date}
          id="percentile-hint"
          class="text-xs opacity-60 px-3 py-2 border-t border-base-300"
        >
          Add a birth date to see CDC growth percentiles.
          <.link navigate={~p"/children/#{@current_child}/edit"} class="underline">Edit child</.link>
        </p>
      </section>

      <section class="mt-6 rounded-box border border-base-300 overflow-hidden">
        <div class="px-3 py-2.5 border-b border-base-300 bg-base-200/40">
          <h2 class="font-semibold">History</h2>
        </div>
        <p :if={@measurements == []} class="opacity-60 text-sm py-10 text-center px-3">
          No measurements yet.
        </p>
        <div :if={@measurements != []} id="growth-table" class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Date</th>
                <th>Weight</th>
                <th>Height</th>
                <th>By</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={m <- @measurements}
                id={"measurement-#{m.id}"}
                class={[
                  "h-12",
                  @can_write && "cursor-pointer active:bg-base-200"
                ]}
                phx-click={@can_write && JS.push("edit", value: %{id: m.id})}
              >
                <td class="whitespace-nowrap tabular-nums">{format_date(m, @current_child)}</td>
                <td class="tabular-nums">
                  {Units.format(m.weight_g, :weight, @unit_system) || "—"}
                </td>
                <td class="tabular-nums">
                  {Units.format(m.height_cm, :length, @unit_system) || "—"}
                </td>
                <td class="opacity-60 truncate max-w-20">
                  {m.logged_by && User.capitalize_name(m.logged_by.first_name)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <.sheet :if={@sheet} form={@form} editing={@editing} unit_system={@unit_system} />
    </Layouts.app>
    """
  end

  attr :velocity, :map, required: true
  attr :growth_burst, :map, default: nil
  attr :child, Child, required: true
  attr :unit_system, :atom, required: true
  attr :can_write, :boolean, default: false

  defp weight_gain_card(assigns) do
    ~H"""
    <section id="weight-gain-card" class="mt-4 rounded-box border border-base-300 overflow-hidden">
      <div class="bg-base-200/40 px-3 py-2 flex items-baseline justify-between gap-2">
        <h2 class="font-semibold text-sm">Weight gain</h2>
        <span :if={@velocity.available?} class="text-xs opacity-60 tabular-nums">
          {Calendar.strftime(@velocity.prior.date, "%-d %b")} → {Calendar.strftime(
            @velocity.latest.date,
            "%-d %b"
          )}
        </span>
      </div>
      <div class="p-3 space-y-2 text-sm">
        <%= if @velocity.available? do %>
          <div class="flex items-baseline gap-2">
            <span id="weight-gain-rate" class="text-xl font-semibold tabular-nums">
              {gain_per_week(@velocity.velocity.g_per_week, @unit_system)}
            </span>
            <span class="opacity-60">over {@velocity.velocity.days} days</span>
          </div>
          <p :if={@velocity.velocity.expected_gain_g} id="weight-gain-expected" class="opacity-70">
            Expected about {gain_label(@velocity.velocity.expected_gain_g, @unit_system)} in that
            time to hold the {Percentiles.format_percentile(@velocity.velocity.percentile_prev)} percentile
            — actual {gain_label(@velocity.velocity.gain_g, @unit_system)}.
          </p>
          <p :if={@velocity.velocity.percentile_now} id="weight-gain-percentile" class="opacity-70">
            Percentile {Percentiles.format_percentile(@velocity.velocity.percentile_prev)} →
            <span class="font-medium">
              {Percentiles.format_percentile(@velocity.velocity.percentile_now)}
            </span>
            <span :if={@velocity.velocity.percentile_drop?} class="text-warning">
              · crossed a major band, worth mentioning at the next visit
            </span>
          </p>
          <p
            :if={!@velocity.velocity.percentile_now && @velocity.velocity.guide_g_per_day}
            id="weight-gain-guide"
            class="opacity-70"
          >
            {guide_copy(@velocity.velocity)}
          </p>
        <% else %>
          <p id="weight-gain-empty" class="opacity-60">
            {if @velocity.latest,
              do: "Log another weight at least 5 days apart and the gain rate will show here.",
              else: "Log a weight to start tracking gain."}
          </p>
        <% end %>

        <p :if={@velocity.newborn} id="weight-gain-newborn" class="opacity-70">
          {newborn_copy(@velocity.newborn, @unit_system)}
        </p>

        <div
          :if={@velocity.prompt_birth_weight? and @can_write}
          id="birth-weight-prompt"
          class="rounded-box bg-base-200 border border-base-300 p-2.5 flex items-center gap-2"
        >
          <p class="text-xs opacity-80 flex-1">
            Add a weight dated {Calendar.strftime(@child.birth_date, "%-d %b")} (birth) to track
            the first-week dip and regain.
          </p>
          <.button
            type="button"
            size="sm"
            variant="outline"
            phx-click="open_sheet"
            phx-value-date={Date.to_iso8601(@child.birth_date)}
          >
            Add
          </.button>
        </div>

        <div
          :if={@growth_burst && @growth_burst.active?}
          id="growth-burst-note"
          class="rounded-box bg-base-200 border border-base-300 p-2.5 flex items-center gap-2"
        >
          <p class="text-xs opacity-80 flex-1">
            Sleeping more than usual on {Calendar.strftime(@growth_burst.on, "%a %-d %b")}. In one
            diary study (Lampl &amp; Johnson, 2011) bursts like this came 0–4 days before a
            length spurt — a good moment to measure.
          </p>
          <.button
            :if={@can_write}
            type="button"
            size="sm"
            variant="outline"
            phx-click="open_sheet"
          >
            Measure
          </.button>
        </div>
      </div>
    </section>
    """
  end

  defp gain_per_week(g_per_week, units), do: gain_label(g_per_week, units) <> "/week"

  defp gain_label(grams, :imperial) do
    oz = grams / 28.349523125
    "#{sign(oz)}#{:erlang.float_to_binary(abs(oz) * 1.0, decimals: 1)} oz"
  end

  defp gain_label(grams, _metric), do: "#{sign(grams)}#{round(abs(grams))} g"

  defp sign(n) when n < 0, do: "−"
  defp sign(_n), do: "+"

  defp guide_copy(%{guide_g_per_day: {lo, hi}, g_per_day: rate, guide_status: status}) do
    base = "About #{round(rate)} g a day; typical for their age is #{lo}–#{hi} g a day"

    case status do
      :below -> base <> " — a bit under, worth mentioning at the next visit."
      :above -> base <> " — a bit over, which is common and usually fine."
      _ -> base <> "."
    end
  end

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

  attr :period, :atom, required: true

  defp chart_toolbar(assigns) do
    assigns = assign(assigns, :periods, periods())

    ~H"""
    <div id="chart-range" class="grid grid-cols-6 gap-1.5">
      <.button
        :for={{id, label, _} <- @periods}
        id={"chart-period-#{id}"}
        type="button"
        variant={if @period == id, do: "primary", else: "outline"}
        size="sm"
        phx-click="chart_period"
        phx-value-period={id}
        class="min-h-11 px-0"
      >
        {label}
      </.button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :kind, :string, required: true
  attr :title, :string, required: true
  attr :unit, :string, required: true
  attr :chart, :map, required: true

  defp trend_chart(assigns) do
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
        :if={!@chart.empty? and !@chart.empty_range?}
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

  attr :form, :any, required: true
  attr :editing, :any, default: nil
  attr :unit_system, :atom, required: true

  defp sheet(assigns) do
    assigns =
      assign(assigns,
        weight_unit: Units.unit_label(:weight, assigns.unit_system),
        height_unit: Units.unit_label(:length, assigns.unit_system)
      )

    ~H"""
    <div
      id="growth-sheet"
      class="fixed inset-0 z-50 flex items-end sm:items-center justify-center"
      phx-window-keydown="close_sheet"
      phx-key="escape"
    >
      <div class="absolute inset-0 bg-black/60" phx-click="close_sheet"></div>
      <div class="relative w-full sm:max-w-md bg-base-100 border-t border-base-300 sm:border sm:rounded-box rounded-t-2xl p-5 pb-[calc(env(safe-area-inset-bottom)+1.25rem)] max-h-[90dvh] overflow-y-auto">
        <h3 class="font-semibold text-lg mb-3">
          {if @editing, do: "Edit measurement", else: "Log height and weight"}
        </h3>
        <.form for={@form} id="growth-form" phx-submit="save" class="space-y-3">
          <.input
            field={@form[:weight]}
            type="number"
            step="any"
            min="0"
            label={"Weight (#{@weight_unit})"}
          />
          <.input
            field={@form[:height]}
            type="number"
            step="any"
            min="0"
            label={"Height (#{@height_unit})"}
          />
          <.input field={@form[:measured_on]} type="date" label="Date" />
          <.input field={@form[:note]} type="text" label="Note" placeholder="Optional" />

          <div class="flex gap-2 pt-2">
            <.button type="submit" variant="primary" size="lg" class="flex-1 min-h-12 text-base">
              Save
            </.button>
            <.button
              type="button"
              variant="ghost"
              size="lg"
              class="min-h-12"
              phx-click="close_sheet"
            >
              Cancel
            </.button>
          </div>
          <.button
            :if={@editing}
            id="delete-measurement"
            type="button"
            variant="outline"
            phx-click="delete"
            data-confirm="Delete this measurement?"
            class="btn-error w-full mt-2 min-h-11"
          >
            Delete
          </.button>
        </.form>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Trygg.Accounts.subscribe_user(socket.assigns.current_scope.user.id)

    socket =
      socket
      |> assign(:unit_system, socket.assigns.current_scope.user.unit_system)
      |> assign(:can_write, socket.assigns.role in [:owner, :caregiver])
      |> assign(:sheet, false)
      |> assign(:form, nil)
      |> assign(:editing, nil)
      |> assign(:chart_period, :all)
      |> assign(:selected_point, nil)
      |> load_measurements()

    {:ok, socket}
  end

  @impl true
  def handle_info({:growth, _action, _measurement}, socket),
    do: {:noreply, load_measurements(socket)}

  def handle_info({:child_updated, child}, socket) do
    {:noreply,
     socket
     |> assign(:current_child, %{child | role: socket.assigns.role})
     |> load_measurements()}
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
     |> load_measurements()}
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
        |> assign(:current_child, child)
        |> assign(:current_scope, Scope.put_child(scope, child, role))
    end
  end

  @impl true
  def handle_event("open_sheet", params, socket) do
    if socket.assigns.can_write do
      today = Child.local_today(socket.assigns.current_child)

      date =
        case parse_date(params["date"]) do
          {:ok, d} -> d
          :error -> today
        end

      {:noreply,
       socket
       |> assign(:sheet, true)
       |> assign(:editing, nil)
       |> assign(:form, to_form(blank_params(date), as: :measurement))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_sheet", _params, socket) do
    {:noreply, assign(socket, sheet: false, form: nil, editing: nil)}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    if socket.assigns.can_write do
      measurement = Growth.get_measurement!(socket.assigns.current_scope, id)

      {:noreply,
       socket
       |> assign(:sheet, true)
       |> assign(:editing, measurement)
       |> assign(
         :form,
         to_form(
           edit_params(measurement, socket.assigns.current_child, socket.assigns.unit_system),
           as: :measurement
         )
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save", %{"measurement" => params}, socket) do
    if socket.assigns.can_write do
      {:noreply, save_measurement(socket, params)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete", _params, socket) do
    if socket.assigns.can_write && socket.assigns.editing do
      {:ok, _} = Growth.delete_measurement(socket.assigns.current_scope, socket.assigns.editing)

      {:noreply,
       socket
       |> assign(sheet: false, form: nil, editing: nil, selected_point: nil)
       |> load_measurements()
       |> put_flash(:info, "Deleted.")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("chart_period", %{"period" => period}, socket) do
    {:noreply,
     socket
     |> assign(:chart_period, parse_period(period))
     |> assign(:selected_point, nil)
     |> rebuild_charts()}
  end

  def handle_event("chart_zoom", %{"dir" => dir}, socket) do
    period = zoom(socket.assigns.chart_period, dir)

    {:noreply,
     socket
     |> assign(:chart_period, period)
     |> assign(:selected_point, nil)
     |> rebuild_charts()}
  end

  def handle_event("select_point", %{"chart" => chart, "id" => id}, socket) do
    key = {chart, id}
    selected = if socket.assigns.selected_point == key, do: nil, else: key
    {:noreply, socket |> assign(:selected_point, selected) |> rebuild_charts()}
  end

  defp save_measurement(socket, params) do
    child = socket.assigns.current_child
    units = socket.assigns.unit_system
    form = to_form(params, as: :measurement)

    with {:ok, date} <- parse_date(params["measured_on"]),
         :ok <- not_future(child, date),
         attrs <- %{
           "measured_on" => date,
           "weight_g" => from_display(params["weight"], :weight, units),
           "height_cm" => from_display(params["height"], :length, units),
           "note" => blank(params["note"])
         },
         {:ok, _m} <- persist(socket, attrs) do
      socket
      |> assign(sheet: false, form: nil, editing: nil, selected_point: nil)
      |> load_measurements()
      |> put_flash(:info, "Saved.")
    else
      :error ->
        socket
        |> assign(:form, form)
        |> put_flash(:error, "That date didn't look right.")

      {:error, :future} ->
        socket
        |> assign(:form, form)
        |> put_flash(:error, "That's in the future — pick an earlier date.")

      {:error, %Ecto.Changeset{} = cs} ->
        socket
        |> assign(:form, form)
        |> put_flash(:error, changeset_flash(cs))
    end
  end

  defp persist(socket, attrs) do
    scope = socket.assigns.current_scope
    child = socket.assigns.current_child

    case socket.assigns.editing do
      nil -> Growth.create_measurement(scope, child, attrs)
      %Measurement{} = m -> Growth.update_measurement(scope, m, attrs)
    end
  end

  defp load_measurements(socket) do
    scope = socket.assigns.current_scope
    child = socket.assigns.current_child
    measurements = Growth.list_measurements(scope, child)

    weight = Growth.latest_weight(scope, child)
    height = Growth.latest_height(scope, child)

    socket
    |> assign(:measurements, measurements)
    |> assign(:latest_weight, weight)
    |> assign(:latest_height, height)
    |> assign(:weight_percentile, metric_percentile(weight, :weight_g, :weight, child))
    |> assign(:height_percentile, metric_percentile(height, :height_cm, :length, child))
    |> assign(:velocity, Velocity.summarize(child, measurements))
    |> assign(:growth_burst, Reports.growth_burst(scope, child))
    |> rebuild_charts()
  end

  defp rebuild_charts(socket) do
    child = socket.assigns.current_child
    units = socket.assigns.unit_system
    measurements = socket.assigns.measurements
    period = socket.assigns.chart_period
    selected = socket.assigns.selected_point
    {from, to} = date_window(child, period, measurements)

    socket
    |> assign(:chart_window_label, window_label(from, to))
    |> assign(:percentile_hint, Percentiles.hint(child))
    |> assign(:percentile_note, Percentiles.source_label(child))
    |> assign(
      :weight_chart,
      build_chart(measurements, :weight_g, :weight, units, child, from, to, selected, "weight")
    )
    |> assign(
      :height_chart,
      build_chart(measurements, :height_cm, :length, units, child, from, to, selected, "height")
    )
  end

  defp blank_params(today) do
    %{"weight" => "", "height" => "", "measured_on" => Date.to_iso8601(today), "note" => ""}
  end

  defp edit_params(%Measurement{} = m, %Child{} = child, units) do
    %{
      "weight" => display_input(m.weight_g, :weight, units),
      "height" => display_input(m.height_cm, :length, units),
      "measured_on" => Date.to_iso8601(local_date(child, m.measured_at)),
      "note" => m.note || ""
    }
  end

  defp display_input(nil, _kind, _units), do: ""

  defp display_input(value, kind, units) do
    value |> Units.to_display(kind, units) |> to_string()
  end

  defp from_display(raw, kind, units) do
    case parse_number(raw) do
      nil -> nil
      n -> Units.from_display(n, kind, units)
    end
  end

  defp parse_number(nil), do: nil
  defp parse_number(""), do: nil
  defp parse_number(n) when is_number(n), do: n * 1.0

  defp parse_number(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_date(nil), do: :error
  defp parse_date(""), do: :error

  defp parse_date(%Date{} = date), do: {:ok, date}

  defp parse_date(iso) when is_binary(iso) do
    case Date.from_iso8601(String.trim(iso)) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_date(_), do: :error

  defp not_future(%Child{} = child, %Date{} = date) do
    if Date.after?(date, Child.local_today(child)), do: {:error, :future}, else: :ok
  end

  defp blank(nil), do: nil
  defp blank(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))

  defp changeset_flash(cs) do
    cond do
      errors_has?(cs, :child_id) ->
        "There's already a measurement on that day — tap it in the table to edit."

      errors_has?(cs, :weight_g) or errors_has?(cs, :height_cm) ->
        "Enter a weight, a height, or both."

      errors_has?(cs, :measured_at) ->
        "That's in the future — pick an earlier date."

      true ->
        "Hmm, that didn't save — try again."
    end
  end

  defp errors_has?(%Ecto.Changeset{errors: errors}, field), do: Keyword.has_key?(errors, field)

  defp metric_value(nil, _field, _kind, _units), do: "—"

  defp metric_value(measurement, field, kind, units) do
    Units.format(Map.get(measurement, field), kind, units) || "—"
  end

  defp metric_sub(nil, _child), do: "Not logged yet"
  defp metric_sub(measurement, child), do: format_date(measurement, child)

  defp metric_percentile(nil, _field, _kind, _child), do: nil

  defp metric_percentile(measurement, field, kind, child) do
    measured_on = local_date(child, measurement.measured_at)

    measurement
    |> Map.get(field)
    |> then(&Percentiles.percentile(child, kind, &1, measured_on))
    |> Percentiles.format_percentile()
  end

  defp format_date(%Measurement{measured_at: dt}, %Child{} = child) do
    child |> local_date(dt) |> Calendar.strftime("%-d %b %Y")
  end

  defp local_date(%Child{timezone: tz}, %DateTime{} = dt) do
    dt |> DateTime.shift_zone!(tz) |> DateTime.to_date()
  end

  defp periods, do: @periods

  defp parse_period(value) do
    Enum.find_value(@periods, :all, fn {id, _label, _days} ->
      if to_string(id) == to_string(value), do: id
    end)
  end

  defp zoom(period, dir) do
    order = Enum.map(@periods, &elem(&1, 0))
    idx = Enum.find_index(order, &(&1 == period)) || length(order) - 1

    case dir do
      "in" -> Enum.at(order, max(idx - 1, 0))
      _ -> Enum.at(order, min(idx + 1, length(order) - 1))
    end
  end

  defp date_window(%Child{} = child, period, measurements) do
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

  defp window_label(from, to) do
    if Date.compare(from, to) == :eq do
      Calendar.strftime(to, "%-d %b %Y")
    else
      "#{Calendar.strftime(from, "%-d %b")} – #{Calendar.strftime(to, "%-d %b %Y")}"
    end
  end

  defp build_chart(measurements, field, kind, units, child, from, to, selected, chart_kind) do
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

  defp compact_age(nil), do: nil
  defp compact_age({0, 0, 0}), do: "0d"
  defp compact_age({0, 0, d}), do: "#{d}d"
  defp compact_age({0, m, _d}), do: "#{m}mo"
  defp compact_age({y, 0, _d}), do: "#{y}y"
  defp compact_age({y, m, _d}), do: "#{y}y #{m}mo"

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
