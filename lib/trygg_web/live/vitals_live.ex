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
  alias TryggWeb.GrowthComponents
  alias TryggWeb.{Loading, RemoteUpdate}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_child={@current_child}
      current_tab={:vitals}
      children={@children}
      child_switch_to={:vitals}
      title="Vitals"
      back={~p"/c/#{@current_child}"}
      wide
    >
      <%!-- Phone order is stats → charts → history. From md the charts take
           the right column, spanning both rows, with history under the stats;
           the `1fr` row soaks up the charts' extra height so history doesn't
           drift down. --%>
      <.loadable id="vitals-content" loaded={@loaded?} failed={@load_failed?}>
        <:skeleton><.vitals_skeleton can_write={@can_write} /></:skeleton>
        <div
          id="vitals-columns"
          class="md:grid md:grid-cols-2 md:grid-rows-[auto_1fr] md:items-start md:gap-x-6"
        >
          <div class="md:col-start-1 min-w-0">
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
          </div>

          <section
            id="growth-charts"
            class="mt-6 md:mt-0 md:col-start-2 md:row-span-2 md:row-start-1 min-w-0 rounded-box border border-base-300 overflow-hidden"
          >
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
              <.age_basis_toggle :if={@age_basis_toggle?} basis={@age_basis} />
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
              class="text-xs opacity-60 px-3 py-2 border-t border-base-300"
            >
              {@percentile_note} · 5th–95th
              <span :if={@corrected_age} id="corrected-age">· {@corrected_age}</span>
            </p>
            <p
              :if={@age_basis == :actual and @age_basis_toggle?}
              id="percentile-actual-age"
              class="text-xs opacity-60 px-3 py-2 border-t border-base-300"
            >
              Showing actual age, not corrected for birth at {Child.gestation_label(@current_child)}.
            </p>
            <p
              :if={@percentile_hint == :before_preterm_chart}
              id="percentile-hint"
              class="text-xs opacity-60 px-3 py-2 border-t border-base-300"
            >
              Born at {Child.gestation_label(@current_child)}, so corrected percentiles begin on {Calendar.strftime(
                Percentiles.first_date(@current_child),
                "%b %-d"
              )}, at 27 weeks — the earliest age the INTERGROWTH-21st preterm standard covers.
            </p>
            <p
              :if={@percentile_hint == :unspecified_sex}
              id="percentile-hint"
              class="text-xs opacity-60 px-3 py-2 border-t border-base-300"
            >
              Set this child's sex to girl or boy to see CDC growth percentiles.
              <.link navigate={~p"/children/#{@current_child}/edit"} class="underline">
                Edit child
              </.link>
            </p>
            <p
              :if={@percentile_hint == :no_birth_date}
              id="percentile-hint"
              class="text-xs opacity-60 px-3 py-2 border-t border-base-300"
            >
              Add a birth date to see CDC growth percentiles.
              <.link navigate={~p"/children/#{@current_child}/edit"} class="underline">
                Edit child
              </.link>
            </p>
          </section>

          <section class="mt-6 md:col-start-1 min-w-0 rounded-box border border-base-300 overflow-hidden">
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
        </div>
      </.loadable>

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
            {guide_copy(@velocity.velocity, @unit_system)}
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

  attr :period, :atom, required: true

  defp chart_toolbar(assigns) do
    assigns = assign(assigns, :periods, GrowthComponents.periods())

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

  attr :basis, :atom, required: true

  # Corrected vs actual age, so a caregiver can match whichever chart their
  # pediatrician uses.
  defp age_basis_toggle(assigns) do
    ~H"""
    <div id="age-basis" class="join w-full" role="group" aria-label="Age used for percentiles">
      <button
        :for={{basis, label} <- [corrected: "Corrected age", actual: "Actual age"]}
        id={"age-basis-#{basis}"}
        type="button"
        phx-click="age_basis"
        phx-value-basis={basis}
        aria-pressed={to_string(@basis == basis)}
        class={["join-item btn btn-sm flex-1 min-h-11", @basis == basis && "btn-primary"]}
      >
        {label}
      </button>
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
    <.sheet_frame
      id="growth-sheet"
      close="close_sheet"
      label={if @editing, do: "Edit measurement", else: "Log height and weight"}
    >
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
          <.button type="submit" variant="primary" class="flex-1">
            Save
          </.button>
          <.button type="button" variant="ghost" phx-click="close_sheet">
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
    </.sheet_frame>
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
      |> assign(:age_basis, :corrected)
      |> assign(:selected_point, nil)
      |> Loading.init()
      |> load_measurements()

    {:ok, socket}
  end

  @impl true
  def handle_async(:load, result, socket),
    do: {:noreply, Loading.done(socket, result, &apply_measurements/2)}

  @impl true
  def handle_info({:growth, action, measurement}, socket),
    do: {:noreply, socket |> load_measurements() |> RemoteUpdate.flash_growth(measurement, action)}

  def handle_info({:child_updated, child}, socket) do
    {:noreply,
     socket
     |> assign(:current_child, %{child | role: socket.assigns.role})
     |> load_measurements()}
  end

  def handle_info({:child_born, child}, socket) do
    {:noreply,
     socket
     |> assign(:current_child, %{child | role: socket.assigns.role})
     |> put_flash(:info, "#{child.name} is here! 🎉 Practice entries cleared.")
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
  def handle_event("retry_load", _params, socket), do: {:noreply, load_measurements(socket)}

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

  def handle_event("age_basis", %{"basis" => basis}, socket) do
    basis = if basis == "actual", do: :actual, else: :corrected

    {:noreply,
     socket
     |> assign(:age_basis, basis)
     |> assign(:selected_point, nil)
     |> load_measurements()}
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

  # The first load goes through `TryggWeb.Loading` (skeleton, then a task);
  # after that, saves and realtime updates reload in place.
  defp load_measurements(socket) do
    scope = socket.assigns.current_scope
    child = socket.assigns.current_child
    fetch = fn -> fetch_measurements(scope, child) end

    if socket.assigns.loaded?,
      do: apply_measurements(socket, fetch.()),
      else: Loading.run(socket, fetch, &apply_measurements/2)
  end

  defp fetch_measurements(scope, child) do
    %{
      measurements: Growth.list_measurements(scope, child),
      weight: Growth.latest_weight(scope, child),
      height: Growth.latest_height(scope, child),
      growth_burst: Reports.growth_burst(scope, child)
    }
  end

  defp apply_measurements(
         socket,
         %{measurements: measurements, weight: weight, height: height} = data
       ) do
    scored = scored_child(socket)

    socket
    |> assign(:measurements, measurements)
    |> assign(:latest_weight, weight)
    |> assign(:latest_height, height)
    |> assign(:weight_percentile, metric_percentile(weight, :weight_g, :weight, scored))
    |> assign(:height_percentile, metric_percentile(height, :height_cm, :length, scored))
    |> assign(:velocity, Velocity.summarize(scored, measurements))
    |> assign(:growth_burst, data.growth_burst)
    |> rebuild_charts()
  end

  defp rebuild_charts(socket) do
    child = scored_child(socket)
    units = socket.assigns.unit_system
    measurements = socket.assigns.measurements
    period = socket.assigns.chart_period
    selected = socket.assigns.selected_point
    {from, to} = GrowthComponents.date_window(child, period, measurements)

    socket
    |> assign(:chart_window_label, GrowthComponents.window_label(from, to))
    |> assign(:age_basis_toggle?, age_basis_toggle?(socket.assigns.current_child))
    |> assign(:percentile_hint, Percentiles.hint(child, hint_date(socket, child)))
    |> assign(:percentile_note, Percentiles.source_label(child))
    |> assign(:corrected_age, corrected_age_label(child))
    |> assign(
      :weight_chart,
      GrowthComponents.build_chart(measurements, :weight_g, :weight, units, child, from, to,
        selected: selected,
        chart_kind: "weight"
      )
    )
    |> assign(
      :height_chart,
      GrowthComponents.build_chart(measurements, :height_cm, :length, units, child, from, to,
        selected: selected,
        chart_kind: "height"
      )
    )
  end

  # The child as percentiles should see them under the chosen age basis.
  defp scored_child(%{assigns: %{age_basis: :actual, current_child: child}}),
    do: Child.uncorrected(child)

  defp scored_child(socket), do: socket.assigns.current_child

  defp age_basis_toggle?(child), do: Child.born_early?(child) and Percentiles.available?(child)

  # Explain missing percentiles for the earliest of today and the latest
  # readings — a badge can be blank because its reading predates 27 weeks.
  defp hint_date(socket, child) do
    [socket.assigns.latest_weight, socket.assigns.latest_height]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&local_date(child, &1.measured_at))
    |> Enum.min(Date, fn -> Child.local_today(child) end)
  end

  # "corrected age 1mo 2d", plus the postmenstrual age the preterm standard is
  # read at while it applies (alone before the 40-week date).
  defp corrected_age_label(child) do
    today = Child.local_today(child)
    pma = "#{Child.postmenstrual_age_label(child, today)} postmenstrual"

    cond do
      not Percentiles.corrected?(child, today) ->
        nil

      Date.before?(today, Child.term_date(child)) ->
        pma

      Percentiles.standard_on(child, today) == :intergrowth ->
        "#{corrected_age_text(child, today)} · #{pma}"

      true ->
        corrected_age_text(child, today)
    end
  end

  defp corrected_age_text(child, today) do
    {y, m, d} = Child.corrected_age(child, today)
    if y > 0, do: "corrected age #{y}y #{m}mo #{d}d", else: "corrected age #{m}mo #{d}d"
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

  defp local_date(child, dt), do: GrowthComponents.local_date(child, dt)

  defp parse_period(value) do
    Enum.find_value(GrowthComponents.periods(), :all, fn {id, _label, _days} ->
      if to_string(id) == to_string(value), do: id
    end)
  end

  defp zoom(period, dir) do
    order = Enum.map(GrowthComponents.periods(), &elem(&1, 0))
    idx = Enum.find_index(order, &(&1 == period)) || length(order) - 1

    case dir do
      "in" -> Enum.at(order, max(idx - 1, 0))
      _ -> Enum.at(order, min(idx + 1, length(order) - 1))
    end
  end
end
