defmodule TryggWeb.SleepScheduleComponents do
  @moduledoc """
  The panels of the Sleep schedule page: the day as it stands (the guide for
  their age with the family's own choices on top) and the form for changing it.
  Fed by `Trygg.Reports.sleep_schedule/3`.
  """
  use Phoenix.Component

  import TryggWeb.CoreComponents
  import TryggWeb.LogComponents, only: [format_duration: 1, clock: 2]

  alias Trygg.Sleep.DaySchedule
  alias Trygg.TimeFormat

  @doc "The day as it stands. `eff` is a `Trygg.Sleep.DaySchedules.effective/4` map."
  attr :eff, :map, required: true
  attr :tz, :string, required: true
  attr :can_write, :boolean, required: true

  def schedule_day_panel(assigns) do
    ~H"""
    <section id="schedule-day" class={panel_class()}>
      <div class="flex items-baseline justify-between gap-3">
        <h2 class={heading_class()}>
          {if @eff.mode == :newborn, do: "Their rhythm", else: "Their day"}
        </h2>
        <span id="schedule-guide-label" class="text-xs opacity-70">
          {@eff.label}{if @eff.customized?, do: " · your changes", else: " · the guide"}
        </span>
      </div>

      <div
        :if={@eff.stale?}
        id="schedule-stale"
        class="mb-3 rounded-box border border-warning/50 bg-warning/10 p-3 text-sm"
      >
        <p>
          They've moved up to a new stage since you set this. Look it over: your choices still apply
          until you change them.
        </p>
        <.button
          :if={@can_write}
          id="schedule-keep"
          phx-click="keep_guide"
          size="sm"
          class="mt-2"
        >
          Keep my settings
        </.button>
      </div>

      <%= if @eff.mode == :guide do %>
        <table id="schedule-items" class="w-full text-sm">
          <tbody>
            <tr id="schedule-wake-row" class="border-t border-base-300">
              <th scope="row" class="py-1.5 pr-3 text-left font-medium whitespace-nowrap">
                Wake-up
              </th>
              <td class="tabular-nums">
                <%= if @eff.anchor == :today do %>
                  {clock(@eff.wake_at, @tz)}
                  <span class="ml-1 text-xs opacity-70">today</span>
                <% else %>
                  {TimeFormat.clock(@eff.wake.minutes)}
                  <span class="ml-1 text-xs opacity-70">{wake_note(@eff)}</span>
                <% end %>
              </td>
            </tr>
            <tr
              :for={item <- @eff.day.items}
              id={"schedule-#{item.kind}-#{item.ordinal || "bed"}"}
              class="border-t border-base-300"
            >
              <th scope="row" class="py-1.5 pr-3 text-left font-medium whitespace-nowrap">
                {item_label(item)}
              </th>
              <td class="tabular-nums">
                {item_time(item, @tz)}
                <span
                  :if={item.kind == :bed and @eff.bedtime.source == :pinned}
                  class="ml-1 text-xs opacity-70"
                >
                  yours
                </span>
              </td>
            </tr>
          </tbody>
        </table>
        <p :for={note <- @eff.day.notes} class="mt-2 text-xs opacity-70">{day_note(note)}</p>
        <p class="mt-2 text-xs opacity-70">
          {@eff.table.naps} naps, from this morning's wake-up. A routine to practise, not a timetable:
          watch them as well as the clock.
        </p>
      <% else %>
        <dl id="schedule-anchors" class="space-y-1.5 text-sm">
          <div class="flex justify-between gap-3 border-t border-base-300 pt-1.5">
            <dt class="font-medium">Wake-up</dt>
            <dd class="tabular-nums">
              {TimeFormat.clock(@eff.wake.minutes)}
              <span class="ml-1 text-xs opacity-70">{wake_note(@eff)}</span>
            </dd>
          </div>
          <div
            id="schedule-evening-row"
            class="flex justify-between gap-3 border-t border-base-300 pt-1.5"
          >
            <dt class="font-medium">Evening</dt>
            <dd class="tabular-nums">
              <%= if @eff.bedtime do %>
                {TimeFormat.clock(@eff.bedtime.minutes)}
                <span class="ml-1 text-xs opacity-70">{evening_note(@eff.bedtime)}</span>
              <% else %>
                <span class="opacity-70">not set</span>
              <% end %>
            </dd>
          </div>
          <div
            :if={@eff.newborn.wake_window}
            id="schedule-wake-window"
            class="flex justify-between gap-3 border-t border-base-300 pt-1.5"
          >
            <dt class="font-medium">Awake between sleeps</dt>
            <dd class="tabular-nums">{duration_range(@eff.newborn.wake_window)}</dd>
          </div>
          <div
            :if={@eff.newborn.naps}
            id="schedule-nap-range"
            class="flex justify-between gap-3 border-t border-base-300 pt-1.5"
          >
            <dt class="font-medium">Day sleeps</dt>
            <dd class="tabular-nums">{count_range(@eff.newborn.naps)} a day</dd>
          </div>
        </dl>
        <p class="mt-2 text-xs opacity-70">
          Newborns don't nap by the clock. Use the wake-up and evening as anchors, and follow their
          sleepy cues for the rest. Nap times start at 13 weeks.
        </p>
      <% end %>
    </section>
    """
  end

  @doc """
  What the log suggests changing, for a caregiver to apply or turn down. `coach`
  is `Trygg.Sleep.ScheduleCoach.suggest/1`'s result, `history` the accepted ones.
  """
  attr :coach, :map, required: true
  attr :history, :list, default: []
  attr :can_write, :boolean, required: true

  def schedule_suggestions_panel(assigns) do
    ~H"""
    <section id="schedule-suggestions" class={panel_class()}>
      <h2 class={heading_class()}>Suggestions</h2>

      <p :if={!@coach.ready?} id="suggestions-waiting" class="text-sm opacity-80">
        After about a week of logged sleep, changes the log points to show up here. Nothing changes
        unless you apply it.
      </p>

      <p :if={@coach.hold} id="suggestions-hold" class="text-sm opacity-80">
        {hold_text(@coach.hold.reason)}
      </p>

      <p
        :if={@coach.ready? and !@coach.hold and @coach.suggestions == []}
        id="suggestions-none"
        class="text-sm opacity-80"
      >
        The schedule matches what they've been doing. Nothing to change.
      </p>

      <ul :if={@coach.suggestions != []} class="space-y-3">
        <li
          :for={s <- @coach.suggestions}
          id={"suggestion-#{s.id}"}
          class="rounded-box border border-base-300 bg-base-100 p-3"
        >
          <p class="font-semibold leading-tight">{s.title}</p>
          <p class="mt-1 text-sm opacity-80">{s.detail}</p>
          <div :if={@can_write} class="mt-2 flex gap-2">
            <.button
              id={"suggestion-#{s.id}-accept"}
              phx-click="accept"
              phx-value-id={s.id}
              size="sm"
              variant="primary"
            >
              Apply
            </.button>
            <.button
              id={"suggestion-#{s.id}-dismiss"}
              phx-click="dismiss"
              phx-value-id={s.id}
              size="sm"
            >
              Not now
            </.button>
          </div>
        </li>
      </ul>

      <details :if={@history != []} id="suggestion-history" class="fold mt-3">
        <summary class="cursor-pointer text-sm font-semibold text-primary">Applied before</summary>
        <ul class="mt-1 space-y-0.5 text-sm">
          <li :for={entry <- Enum.reverse(@history)}>
            <span class="tabular-nums opacity-70">{entry["on"]}</span>
            {entry["title"]}
          </li>
        </ul>
      </details>
    </section>
    """
  end

  defp hold_text(:clock_change),
    do:
      "The clocks change soon. Hold the schedule as it is until you're through it; the clock-change planner in Help has the steps."

  defp hold_text(:rough_patch),
    do:
      "It looks like a rough patch around a common regression age. Changing the day now would mistake a blip for a pattern, so suggestions wait until things settle."

  @doc """
  How the last two weeks lined up with the day above. `fit` is a
  `Trygg.Reports.ScheduleFit.score/3` map.
  """
  attr :fit, :map, required: true
  attr :tz, :string, required: true

  def schedule_fit_panel(%{fit: %{ready?: false}} = assigns) do
    ~H"""
    <section id="schedule-fit" class={panel_class()}>
      <h2 class={heading_class()}>How the last two weeks fit</h2>
      <p id="fit-waiting" class="text-sm opacity-80">
        This lines the day up against what they did once there are about {Trygg.Reports.ScheduleFit.min_days()} complete days of sleep logged. {@fit.days} so far.
      </p>
    </section>
    """
  end

  def schedule_fit_panel(assigns) do
    ~H"""
    <section id="schedule-fit" class={panel_class()}>
      <h2 class={heading_class()}>How the last two weeks fit</h2>
      <ul class="space-y-1.5 text-sm">
        <li :if={@fit.naps} id="fit-naps">
          <span class="font-medium">Naps:</span>
          the schedule has {@fit.naps.scheduled} a day; they took exactly that on {@fit.naps.matched} of {@fit.days} days
          (usually {format_count(@fit.naps.median)}).
        </li>
        <li :for={w <- @fit.windows} id={"fit-window-#{w.ordinal}"}>
          <span class="font-medium">Before nap {w.ordinal}:</span>
          awake {format_duration(w.median * 60)} usually, against {format_duration(w.scheduled * 60)} planned
          ({signed(w.delta)}).
        </li>
        <li :if={@fit.wake} id="fit-wake">
          <span class="font-medium">Wake-up:</span>
          {drift(@fit.wake)} {TimeFormat.clock(@fit.wake.scheduled)}; within 30 minutes of it on {@fit.wake.close} of {@fit.wake.n} mornings.
        </li>
        <li :if={@fit.bedtime} id="fit-bedtime">
          <span class="font-medium">Bedtime:</span>
          {drift(@fit.bedtime)} {TimeFormat.clock(@fit.bedtime.scheduled)}; within 30 minutes of it on {@fit.bedtime.close} of {@fit.bedtime.n} nights.
        </li>
      </ul>
      <p :if={!@fit.naps and !@fit.wake and !@fit.bedtime} id="fit-nothing" class="text-sm opacity-80">
        Nothing to line up yet. Set a wake-up or bedtime below and this shows how closely they keep to it.
      </p>
      <p class="mt-2 text-xs opacity-70">
        A look back over {@fit.days} days, not a grade. A gap that lasts is what the suggestions above pick up on.
      </p>
    </section>
    """
  end

  defp signed(0), do: "on the mark"
  defp signed(n) when n > 0, do: "#{n} min longer"
  defp signed(n), do: "#{-n} min shorter"

  defp drift(%{median_delta: delta}) when abs(delta) <= 10, do: "usually right on"
  defp drift(%{median_delta: delta}) when delta > 0, do: "usually #{delta} min after"
  defp drift(%{median_delta: delta}), do: "usually #{-delta} min before"

  defp format_count(n) when is_float(n),
    do: n |> Float.round(1) |> to_string() |> String.trim_trailing(".0") |> Kernel.<>(" a day")

  defp format_count(n), do: "#{n} a day"

  @doc """
  The form for the family's choices. `form` is built from the params (see
  `Trygg.Sleep.DaySchedules.parse_params/1`); blanks follow the guide.
  """
  attr :form, :map, required: true
  attr :eff, :map, required: true
  attr :can_write, :boolean, required: true

  def schedule_form_panel(assigns) do
    assigns = assign(assigns, :count, slot_count(assigns.form.params, assigns.eff))

    ~H"""
    <section id="schedule-edit" class={panel_class()}>
      <h2 class={heading_class()}>Make it yours</h2>

      <p :if={!@can_write} id="schedule-read-only" class="text-sm opacity-80">
        Only caregivers can change the schedule.
      </p>

      <.form
        :if={@can_write}
        for={@form}
        id="schedule-form"
        phx-change="validate"
        phx-submit="save"
        class="space-y-3"
      >
        <p class="text-sm opacity-80">
          Set only what you want to decide. Anything left blank follows the guide for their age and
          moves along as they grow.
        </p>

        <div class="grid grid-cols-2 gap-3">
          <div>
            <.input field={@form[:wake]} type="time" id="schedule-input-wake" label="Wake-up" />
            <p class="mt-1 text-xs opacity-70">{wake_hint(@eff)}</p>
          </div>
          <div>
            <.input
              field={@form[:bedtime]}
              type="time"
              id="schedule-input-bedtime"
              label={if @eff.mode == :newborn, do: "Evening", else: "Bedtime"}
            />
            <p class="mt-1 text-xs opacity-70">{bedtime_hint(@eff)}</p>
          </div>
        </div>

        <%= if @eff.mode == :guide do %>
          <.input
            field={@form[:naps]}
            type="select"
            id="schedule-input-naps"
            label="Naps a day"
            prompt={"Guide: #{@eff.nap_count.guide}"}
            options={Enum.map(1..DaySchedule.max_naps(), &{Integer.to_string(&1), &1})}
          />

          <fieldset id="schedule-slots" class="space-y-2">
            <legend class="text-sm font-medium">Each nap (minutes)</legend>
            <div
              :for={i <- 0..(@count - 1)}
              id={"schedule-slot-#{i}"}
              class="grid grid-cols-[4.5rem_1fr_1fr] items-end gap-2"
            >
              <span class="pb-2 text-sm">Nap {i + 1}</span>
              <.input
                type="number"
                id={"schedule-window-#{i}"}
                name={"schedule[windows][#{i}]"}
                value={slot_value(@form.params, "windows", i)}
                label="Awake before"
                placeholder={slot_guide(@eff, i, :window)}
                min="20"
                max="480"
              />
              <.input
                type="number"
                id={"schedule-length-#{i}"}
                name={"schedule[lengths][#{i}]"}
                value={slot_value(@form.params, "lengths", i)}
                label="Length"
                placeholder={slot_guide(@eff, i, :nap)}
                min="10"
                max="240"
              />
            </div>
          </fieldset>
        <% end %>

        <div class="flex flex-wrap gap-2">
          <.button id="schedule-save" type="submit" variant="primary">Save</.button>
          <.button
            :if={@eff.customized?}
            id="schedule-reset"
            type="button"
            phx-click="reset"
            data-confirm="Go back to the guide for their age?"
          >
            Back to the guide
          </.button>
        </div>
      </.form>
    </section>
    """
  end

  ## Form helpers ----------------------------------------------------------------

  @doc "Form params (as the form posts them) for a saved `DaySchedule`, or `nil`."
  def form_params(nil),
    do: %{"wake" => "", "bedtime" => "", "naps" => "", "windows" => %{}, "lengths" => %{}}

  def form_params(%DaySchedule{} = s) do
    %{
      "wake" => hhmm(s.wake_minutes),
      "bedtime" => hhmm(s.bedtime_minutes),
      "naps" => if(s.nap_count, do: Integer.to_string(s.nap_count), else: ""),
      "windows" => slot_params(s.wake_windows),
      "lengths" => slot_params(s.nap_lengths)
    }
  end

  defp slot_params(list) do
    list
    |> Enum.with_index()
    |> Map.new(fn {value, i} ->
      {Integer.to_string(i), if(value, do: Integer.to_string(value), else: "")}
    end)
  end

  defp hhmm(nil), do: ""

  defp hhmm(minutes),
    do:
      :io_lib.format("~2..0B:~2..0B", [div(minutes, 60), rem(minutes, 60)])
      |> IO.iodata_to_binary()

  @doc "How many nap rows the form shows: the number chosen, else the guide's."
  def slot_count(params, %{mode: :guide} = eff) do
    case Integer.parse(to_string(params["naps"])) do
      {n, ""} when n in 1..5 -> n
      _ -> eff.nap_count.guide
    end
  end

  def slot_count(_params, _eff), do: 0

  defp slot_value(params, key, i) do
    case params[key] do
      %{} = map -> map[Integer.to_string(i)]
      _ -> nil
    end
  end

  defp slot_guide(eff, i, field) do
    case Enum.at(eff.slots, i) do
      nil -> nil
      slot -> slot |> Map.fetch!(field) |> Map.fetch!(:guide) |> Integer.to_string()
    end
  end

  ## Wording ---------------------------------------------------------------------

  defp wake_hint(%{wake: %{source: :observed}} = eff),
    do: "Blank: their usual, #{TimeFormat.clock(eff.wake.minutes)}."

  defp wake_hint(_eff), do: "Blank: their usual once you've logged a few, else 07:00."

  defp bedtime_hint(%{mode: :guide, table: table}) do
    {lo, hi} = table.bedtime

    "Blank: follows the last nap. The guide's window is #{TimeFormat.clock(lo)}–#{TimeFormat.clock(hi)}."
  end

  defp bedtime_hint(_eff), do: "Blank: their usual evening once you've logged a few."

  defp wake_note(%{wake: %{source: :pinned}}), do: "yours"
  defp wake_note(%{wake: %{source: :observed}}), do: "their usual"
  defp wake_note(_), do: "a default"

  defp evening_note(%{source: :pinned}), do: "yours"
  defp evening_note(_), do: "their usual"

  defp item_label(%{kind: :nap, ordinal: n}), do: "Nap #{n}"
  defp item_label(%{kind: :bed}), do: "Bedtime"

  defp item_time(%{kind: :bed, start: at}, tz), do: clock(at, tz)
  defp item_time(%{start: from, end: to}, tz), do: clock(from, tz) <> "–" <> clock(to, tz)

  defp day_note(:late_naps),
    do: "The naps run late for the bedtime window: shorten the last nap or wake from it sooner."

  defp day_note(:early_bedtime),
    do: "An early bedtime, because the day ended early. Earlier is fine when naps were short."

  defp day_note(:short_gap),
    do:
      "The last nap ends close to your bedtime. Shorten it, or end it earlier, so they're tired enough."

  defp day_note(:long_gap),
    do:
      "A long stretch between the last nap and your bedtime. They may be overtired by then; an earlier bedtime can help."

  defp duration_range({lo, hi}) when lo == hi, do: format_duration(lo * 60)
  defp duration_range({lo, hi}), do: "#{format_duration(lo * 60)}–#{format_duration(hi * 60)}"

  defp count_range({lo, hi}) when lo == hi, do: "#{lo}"
  defp count_range({lo, hi}), do: "#{lo}–#{hi}"

  defp panel_class,
    do: "mb-4 rounded-[var(--radius-card)] border-2 border-base-300 bg-base-200/40 p-4"

  defp heading_class, do: "mb-2 text-sm font-semibold uppercase tracking-wide opacity-70"
end
