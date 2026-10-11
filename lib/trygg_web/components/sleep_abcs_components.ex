defmodule TryggWeb.SleepAbcsComponents do
  @moduledoc """
  The Sleep plan page ("The ABCs of Sleep", `Trygg.Sleep.Abcs`) and night mode's
  check-in screens: the gates before starting, the night-weaning setup, tonight's
  instructions, the night chart and progress, and the nap training signs.

  Fed by `Trygg.Reports.sleep_training/3`.
  """
  use Phoenix.Component

  import TryggWeb.CoreComponents
  import TryggWeb.LogComponents, only: [format_duration: 1, clock: 2]

  alias Trygg.Sleep.{Abcs, BedtimePlan, Checkins, Definitions, NapTraining}
  alias Trygg.Units

  ## Before starting -------------------------------------------------------------

  def abcs_intro(assigns) do
    ~H"""
    <section id="abcs-intro" class={panel_class()}>
      <h2 class={heading_class()}>The ABCs of Sleep</h2>
      <p class="text-sm leading-snug">
        A 14-night plan for babies over 5 months: they learn to put themselves to sleep, with you
        reassuring them without rewarding the crying. It asks for consistency more than anything.
      </p>
      <ul class="mt-3 list-disc space-y-1 pl-5 text-sm leading-snug">
        <li>Their own room and crib; bedtime 7–8 pm; a routine of 30 minutes or less.</li>
        <li>Put them down drowsy but awake. No feeding, rocking or bouncing to sleep.</li>
        <li>
          When they cry, wait. "Pop in" for 15–20 seconds after 5 minutes, again 10 minutes later, then
          every 15, without picking them up.
        </li>
        <li>Night feeds are weaned over about five nights and given only when they're asleep.</li>
        <li>The goal is 11–12 hours in the crib; get them once it's morning and they're quiet.</li>
      </ul>
      <p class="mt-3 text-sm leading-snug opacity-80">
        The guide says to expect crying: on the first night often 40–150 minutes in total, spread
        across the night, easing over the first week. Pop-ins are there so they know you haven't gone.
      </p>
      <p class="mt-3 text-xs opacity-70">
        This is a plan, not medical advice. Don't start with a fever, illness or a tooth about to break
        the skin, and check with your pediatrician first.
      </p>
    </section>
    """
  end

  attr :eligibility, :map, required: true
  attr :can_write, :boolean, required: true
  attr :definition, :atom, default: :abcs

  def gates_panel(assigns) do
    assigns =
      assign(assigns,
        prefix: Atom.to_string(assigns.definition),
        preflight: Definitions.preflight(assigns.definition),
        months: months(assigns.definition)
      )

    ~H"""
    <section id={"#{@prefix}-gates"} class={panel_class()}>
      <h2 class={heading_class()}>Before you start</h2>

      <ul class="space-y-2 text-sm">
        <li id={"#{@prefix}-gate-age"} class="flex gap-2">
          <.gate_icon ok={match?({:ok, _}, @eligibility.age)} />
          <span>{age_text(@eligibility.age, @months)}</span>
        </li>
        <li :if={@eligibility.needs_clearance?} id={"#{@prefix}-gate-clearance"} class="flex gap-2">
          <.gate_icon ok={not is_nil(@eligibility.clearance)} />
          <span>
            <%= if @eligibility.clearance do %>
              Pediatrician OK recorded {Calendar.strftime(@eligibility.clearance, "%b %-d")}.
            <% else %>
              Talk to your pediatrician first, then record it here.
            <% end %>
            <.button
              :if={@can_write}
              id="toggle-training-clearance"
              type="button"
              size="xs"
              class="ml-1"
              phx-click="set_clearance"
              phx-value-kind="sleep_training"
              data-confirm={
                if is_nil(@eligibility.clearance),
                  do: "Record that your pediatrician is fine with sleep training?"
              }
            >
              {if @eligibility.clearance, do: "Clear", else: "My pediatrician said it's OK"}
            </.button>
          </span>
        </li>
      </ul>

      <h3 class="mt-4 text-sm font-semibold">
        Pre-flight
        <span id={"#{@prefix}-preflight-count"} class="font-normal opacity-70">
          {@eligibility.preflight.done} of {@eligibility.preflight.total}
        </span>
      </h3>
      <ul id={"#{@prefix}-preflight"} class="mt-2 space-y-1.5">
        <li
          :for={{id, text} <- @preflight}
          id={"check-#{id}"}
          data-checked={to_string(id not in @eligibility.preflight.missing)}
          class="flex gap-2 text-sm"
        >
          <%= if @can_write do %>
            <button
              type="button"
              phx-click="toggle_check"
              phx-value-id={id}
              role="checkbox"
              aria-checked={to_string(id not in @eligibility.preflight.missing)}
              aria-label={text}
              class="-m-3 shrink-0 touch-manipulation p-3"
            >
              <.icon
                name={
                  if id in @eligibility.preflight.missing,
                    do: "hero-stop",
                    else: "hero-check-circle-solid"
                }
                class={"size-5 " <> if(id in @eligibility.preflight.missing, do: "opacity-70", else: "text-success")}
              />
            </button>
          <% else %>
            <.icon
              name={
                if id in @eligibility.preflight.missing,
                  do: "hero-minus-circle",
                  else: "hero-check-circle-solid"
              }
              class={"mt-0.5 size-5 shrink-0 " <> if(id in @eligibility.preflight.missing, do: "opacity-70", else: "text-success")}
            />
          <% end %>
          <span>{text}</span>
        </li>
      </ul>
    </section>
    """
  end

  defp months(:swap), do: "2 months"
  defp months(:slip), do: "4 months"
  defp months(:abcs), do: "5 months"

  attr :ok, :boolean, required: true

  defp gate_icon(assigns) do
    ~H"""
    <.icon
      name={if @ok, do: "hero-check-circle", else: "hero-minus-circle"}
      class={"mt-0.5 size-5 shrink-0 " <> if(@ok, do: "text-success", else: "opacity-70")}
    />
    """
  end

  defp age_text({:ok, _}, months),
    do: "They're past #{months} (corrected for a baby born early)."

  defp age_text({:locked, nil}, months),
    do: "The plan opens at #{months}, and needs a birth date."

  defp age_text({:locked, on}, months),
    do:
      "The plan opens at #{months}, from #{Calendar.strftime(on, "%b %-d")}. Before then it isn't for them."

  attr :form, :any, required: true
  attr :count, :integer, required: true
  attr :kind, :string, required: true
  attr :unit_system, :atom, required: true
  attr :ready?, :boolean, required: true

  def setup_form(assigns) do
    assigns = assign(assigns, :unit, Units.unit_label(:volume, assigns.unit_system))

    ~H"""
    <section id="abcs-setup" class={panel_class()}>
      <h2 class={heading_class()}>Night feeds</h2>
      <p class="mb-3 text-sm leading-snug opacity-80">
        The plan weans night feeds over about five nights, a little less each night, and only feeds a
        baby who is asleep. Tell it what they have now.
      </p>

      <.form
        for={@form}
        id="abcs-setup-form"
        phx-change="setup_change"
        phx-submit="start_plan"
        class="space-y-3"
      >
        <input type="hidden" name="plan[definition]" value="abcs" />
        <.input
          field={@form[:count]}
          id="setup-count"
          type="select"
          label="Night feeds now"
          options={[{"None", "0"}, {"One", "1"}, {"Two", "2"}, {"Three", "3"}]}
        />

        <div :if={@count > 0} class="space-y-3">
          <.input
            field={@form[:kind]}
            id="setup-kind"
            type="select"
            label="Fed by"
            options={[{"Bottle", "bottle"}, {"Nursing", "nursing"}]}
          />

          <div :for={i <- 1..@count} id={"setup-feed-#{i}"} class="grid grid-cols-2 gap-2">
            <.input field={@form[String.to_atom("time_#{i}")]} type="time" label={"Feed #{i} at"} />
            <.input
              field={@form[String.to_atom("amount_#{i}")]}
              type="number"
              min="1"
              step="any"
              label={if @kind == "bottle", do: "Amount (#{@unit})", else: "Minutes"}
            />
          </div>
          <p class="text-xs opacity-70">
            One feed: pick a time 30–60 minutes before they usually wake. Two: about 10:30 pm and
            3:30 am. Keep the last before 11 pm after the first week.
          </p>
        </div>

        <.button
          id="start-plan"
          variant="primary"
          class="w-full"
          disabled={!@ready?}
          data-confirm="Start night 1 tonight? Plan on 14 nights of staying consistent."
        >
          Start night 1 tonight
        </.button>
        <p :if={!@ready?} id="start-plan-blocked" class="text-xs opacity-70">
          Finish the list above first.
        </p>
      </.form>
    </section>
    """
  end

  ## Following the plan ---------------------------------------------------------

  attr :tonight, :map, required: true
  attr :plan, :map, required: true
  attr :table, :map, default: nil
  attr :unit_system, :atom, required: true
  attr :can_write, :boolean, required: true
  attr :child_id, :integer, required: true

  def tonight_panel(assigns) do
    ~H"""
    <section id="abcs-tonight" class={panel_class()}>
      <h2 class={heading_class()}>
        <%= if @tonight.night == 0 do %>
          Starts tonight
        <% else %>
          <%= if @tonight.finished? do %>
            All {@tonight.nights} nights done
          <% else %>
            Night {@tonight.night} of {@tonight.nights}
          <% end %>
        <% end %>
      </h2>

      <div
        class="h-2 overflow-hidden rounded-full bg-base-300"
        role="progressbar"
        aria-valuemin="0"
        aria-valuemax={@tonight.nights}
        aria-valuenow={min(max(@tonight.night, 0), @tonight.nights)}
      >
        <div
          class="h-full rounded-full bg-primary"
          style={"width: #{round(min(max(@tonight.night, 0), @tonight.nights) / @tonight.nights * 100)}%"}
        >
        </div>
      </div>

      <%= if @tonight.finished? do %>
        <p id="abcs-finished" class="mt-3 text-sm leading-snug">
          That's the 14 nights. Keep doing the same: bedtime in the window, put down awake, and a pop-in
          only when you need one. If sleep slips later (illness, travel, a new skill), start the plan again.
          It usually takes 3–5 nights to get it back.
        </p>
      <% else %>
        <ul class="mt-3 space-y-2 text-sm leading-snug">
          <li id="abcs-bedtime">
            <span class="font-semibold">Bedtime</span>
            between {BedtimePlan.clock(elem(Abcs.bedtime_window(), 0))}–{BedtimePlan.clock(
              elem(Abcs.bedtime_window(), 1)
            )},
            no later. A routine of {Abcs.definition().routine_minutes} minutes or less, ending in their room, then down
            drowsy but awake. Stay 20–30 seconds to stroke their head if you like, then leave.
          </li>
          <li id="abcs-comfort">
            <span class="font-semibold">Pop-ins:</span> {comfort_text(@tonight.touch)} Stay 15–20 seconds, then leave.
            At 5, then 10, then every 15 minutes of crying. If crying turns to whining or calming, wait.
          </li>
          <li id="abcs-goal">
            <span class="font-semibold">Goal:</span>
            11–12 hours in the crib. Before 11 hours, treat any waking as night. From 11 hours, wait for a
            quiet moment, then go and get them with lights on and lots of praise.
          </li>
          <li :if={@tonight.weaning != []} id="abcs-weaning">
            <span class="font-semibold">Night feeds tonight:</span>
            <ul class="mt-1 space-y-0.5">
              <li :for={feed <- @tonight.weaning} class="tabular-nums">
                {BedtimePlan.clock(feed.time)}: {amount_text(
                  feed.amount,
                  @plan.feed_kind,
                  @unit_system
                )}
              </li>
            </ul>
            <span class="block text-xs opacity-70">
              Only feed once they've been asleep 5–10 minutes. A feed isn't a reward for crying; if they're awake at feed
              time, do pop-ins and wait.
            </span>
          </li>
        </ul>

        <.button
          :if={@can_write}
          id="abcs-open-night-mode"
          navigate={"/c/#{@child_id}/sleep/night"}
          variant="primary"
          class="mt-4 w-full"
        >
          <.icon name="hero-moon" class="size-5" /> Open night mode
        </.button>
      <% end %>
    </section>
    """
  end

  defp comfort_text(:touch),
    do:
      "Nights 1 and 2: calm, confident words and soothing touch: rub their head, pat their body. Don't pick them up. If they're standing, you may lay them down once."

  defp comfort_text(:voice),
    do: "From night 3: use only your voice. Don't touch them."

  defp amount_text(nil, _kind, _system), do: "no feed"
  defp amount_text(amount, :nursing, _system), do: "#{amount} min"
  defp amount_text(amount, :bottle, system), do: Units.format(amount * 1.0, :volume, system)
  defp amount_text(amount, _kind, _system), do: to_string(amount)

  attr :nights, :list, required: true
  attr :tz, :string, required: true
  attr :tonight, :map, required: true
  attr :can_write, :boolean, required: true
  attr :definition, :atom, default: :abcs

  def night_chart_panel(assigns) do
    ~H"""
    <section id="abcs-chart" class={panel_class()}>
      <h2 class={heading_class()}>Night chart</h2>

      <p :if={@nights == []} id="abcs-chart-empty" class="text-sm opacity-80">
        Night 1 starts tonight. Each night you work through shows up here.
      </p>

      <details :if={@nights != []} class="fold" id="abcs-chart-log">
        <summary class="cursor-pointer text-sm text-primary">
          {length(@nights)} {if length(@nights) == 1, do: "night", else: "nights"} logged
        </summary>
        <div class="mt-2 overflow-x-auto">
          <table class="w-full min-w-[28rem] text-left text-sm">
            <thead class="text-xs uppercase opacity-70">
              <tr>
                <th class="pb-1 pr-2">Night</th>
                <th class="pb-1 pr-2">Down</th>
                <th class="pb-1 pr-2">To sleep</th>
                <th class="pb-1 pr-2">Wakings</th>
                <th :if={@definition != :swap} class="pb-1 pr-2">Crying</th>
                <th class="pb-1 pr-2">Longest sleep</th>
                <th class="pb-1">Feeds</th>
              </tr>
            </thead>
            <tbody>
              <%= for night <- Enum.reverse(@nights) do %>
                <tr id={"abcs-night-#{night.number}"} class="border-t border-base-300 align-top">
                  <th scope="row" class="py-1.5 pr-2 font-medium">{night.number}</th>
                  <td class="py-1.5 pr-2 tabular-nums">{time_or_dash(night.bedtime, @tz)}</td>
                  <td class="py-1.5 pr-2 tabular-nums">
                    {duration_or_dash(night.bedtime_to_sleep_seconds)}
                  </td>
                  <td class="py-1.5 pr-2 tabular-nums">{night.wakings}</td>
                  <td :if={@definition != :swap} class="py-1.5 pr-2 tabular-nums">
                    {duration_or_dash(night.cry_seconds, true)}
                  </td>
                  <td class="py-1.5 pr-2 tabular-nums">
                    {duration_or_dash(night.longest_sleep_seconds)}
                  </td>
                  <td class="py-1.5 tabular-nums">{night.night_feeds || "—"}</td>
                </tr>
                <tr :if={night.wakes != []} class="text-xs opacity-80">
                  <td></td>
                  <td colspan="6" class="pb-1.5">
                    <span :for={wake <- night.wakes} class="mr-3 inline-block">
                      {clock(wake.started_at, @tz)}: {visit_count(
                        length(wake.pop_in_times),
                        @definition
                      )}{if wake.to_sleep_seconds,
                        do: ", asleep in #{format_duration(wake.to_sleep_seconds)}"}
                    </span>
                  </td>
                </tr>
                <tr :if={night.note} class="text-xs opacity-80">
                  <td></td>
                  <td colspan="6" class="pb-1.5 italic">{night.note}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </details>

      <.form
        :if={@can_write and @nights != [] and @tonight.night >= 1 and not @tonight.finished?}
        for={%{}}
        id="abcs-note-form"
        phx-submit="save_note"
        class="mt-3 flex gap-2"
      >
        <input type="hidden" name="night" value={@tonight.night} />
        <input
          type="text"
          name="note"
          id="abcs-note"
          placeholder={"A note for night #{@tonight.night}"}
          maxlength="200"
          class="input input-sm flex-1"
        />
        <.button size="sm">Save</.button>
      </.form>
    </section>
    """
  end

  attr :progress, :map, required: true
  attr :nights, :list, required: true
  attr :definition, :atom, default: :abcs
  attr :assessment, :any, default: nil

  def progress_panel(assigns) do
    # A SWAP is judged by how long bedtime takes; the others by how much they cry.
    {series, label} =
      if assigns.definition == :swap,
        do:
          {assigns.progress.bedtime_to_sleep_seconds, "Time from put-down to asleep each night."},
        else: {assigns.progress.cry_seconds, "Total time spent crying each night."}

    max_value = series |> Enum.reject(&is_nil/1) |> Enum.max(fn -> 0 end) |> max(1)

    assigns =
      assign(assigns,
        bars: Enum.zip(assigns.nights, series),
        label: label,
        max_value: max_value
      )

    ~H"""
    <section :if={@nights != []} id="abcs-progress" class={panel_class()}>
      <h2 class={heading_class()}>Progress</h2>

      <ol id="abcs-cry-bars" class="space-y-1.5" aria-label={@label}>
        <li
          :for={{night, value} <- @bars}
          id={"abcs-cry-#{night.number}"}
          class="flex items-center gap-2 text-sm"
        >
          <span class="w-12 shrink-0 opacity-70">Night {night.number}</span>
          <span class="h-3 flex-1 overflow-hidden rounded-full bg-base-300">
            <span
              class="block h-full rounded-full bg-primary"
              style={"width: #{round((value || 0) / @max_value * 100)}%"}
            ></span>
          </span>
          <span class="w-14 shrink-0 text-right tabular-nums">{duration_or_dash(value, true)}</span>
        </li>
      </ol>
      <p class="mt-1 text-xs opacity-70">{@label}</p>

      <p
        :if={@assessment}
        id="plan-assessment"
        data-status={elem(@assessment, 0)}
        class="mt-3 text-sm"
      >
        {elem(@assessment, 1)}
      </p>

      <p
        :if={@definition != :swap and is_nil(@assessment) and @progress.trend}
        id="abcs-trend"
        class="mt-3 text-sm"
      >
        {trend_text(@progress.trend)}
      </p>
      <p :if={@definition == :abcs} class="mt-2 text-xs opacity-70">
        It's usually hardest on nights 1 to 5 and gets much easier from there. Early-morning wakings
        (4–6 am) are the last to resolve.
      </p>
    </section>
    """
  end

  # "1 pop-in", "2 pop-ins"; "1 time in", "2 times in" on a gradual plan.
  defp visit_count(1, :swap), do: "1 time in"
  defp visit_count(n, :swap), do: "#{n} times in"
  defp visit_count(1, _definition), do: "1 pop-in"
  defp visit_count(n, _definition), do: "#{n} pop-ins"

  defp trend_text(seconds) when seconds < -300,
    do: "Crying is down #{format_duration(abs(seconds))} from the first night."

  defp trend_text(seconds) when seconds > 300,
    do:
      "Crying is up #{format_duration(seconds)} from the first night. Stay consistent; the first few nights vary."

  defp trend_text(_), do: "Crying is about the same as the first night."

  attr :plan, :map, required: true
  attr :tonight, :map, required: true
  attr :can_write, :boolean, required: true

  def plan_controls(assigns) do
    assigns =
      assign(assigns,
        graduated_slip?:
          assigns.plan.definition == :slip and assigns.plan.options["mode"] != "full"
      )

    ~H"""
    <section id="abcs-controls" class={panel_class()}>
      <h2 class={heading_class()}>If something changes</h2>
      <details class="fold" id="plan-if-changes">
        <summary class="cursor-pointer text-sm text-primary">When to pause the plan</summary>
        <ul class="space-y-1.5 text-sm leading-snug">
          <li>
            <span class="font-semibold">Sick or in pain:</span>
            meet the need and stop the plan. Start again once they're fully well.
          </li>
          <li>
            <span class="font-semibold">A tooth breaking the skin:</span>
            wait 24–48 hours before starting.
          </li>
          <li>
            <span class="font-semibold">Early mornings:</span>
            check the room is dark and the sound machine loud, and that bedtime is
            no later than 7 pm. Never bring them into your bed.
          </li>
        </ul>
      </details>

      <div :if={@can_write} class="mt-3 flex flex-wrap gap-2">
        <.button
          :if={@graduated_slip? and not @tonight.finished?}
          id="go-full"
          type="button"
          size="sm"
          phx-click="go_full"
          data-confirm="Stop going in at all? You can't go back to visits once you've decided not to."
        >
          Switch to no visits
        </.button>
        <.button
          :if={@tonight.finished?}
          id="finish-plan"
          type="button"
          variant="primary"
          size="sm"
          phx-click="finish_plan"
          phx-value-status="completed"
        >
          Mark the plan complete
        </.button>
        <.button
          :if={not @tonight.finished?}
          id="stop-plan"
          type="button"
          size="sm"
          phx-click="finish_plan"
          phx-value-status="stopped"
          data-confirm="Stop the plan? You can start it again later."
        >
          Stop the plan
        </.button>
      </div>
    </section>
    """
  end

  ## Naps ----------------------------------------------------------------------------

  attr :readiness, :map, required: true
  attr :table, :map, default: nil
  attr :night, :integer, default: 0
  attr :can_write, :boolean, required: true

  def nap_panel(assigns) do
    assigns = assign(assigns, steps: NapTraining.steps(), tips: NapTraining.tips())

    ~H"""
    <section id="abcs-naps" class={panel_class()}>
      <h2 class={heading_class()}>Naps</h2>
      <p class="text-sm leading-snug">
        Nights first. Night sleep is learned first and naps follow, using a different part of the brain, so
        for the first 14 nights keep doing what you do for naps, as long as feeds stay every 2.5–4 hours.
        Finish at least night 1 before starting.
      </p>

      <h3 class="mt-3 text-sm font-semibold">
        Signs it's time (any one)
        <span :if={@readiness.any?} id="nap-ready" class="font-normal text-success">: at least one applies</span>
      </h3>
      <ul id="nap-signs" class="mt-2 space-y-1.5">
        <li
          :for={sign <- @readiness.signs}
          id={"check-#{sign.id}"}
          data-checked={to_string(sign.checked?)}
          class="flex gap-2 text-sm"
        >
          <%= if sign.auto? or not @can_write do %>
            <.icon
              name={if sign.checked?, do: "hero-check-circle-solid", else: "hero-minus-circle"}
              class={"mt-0.5 size-5 shrink-0 " <> if(sign.checked?, do: "text-success", else: "opacity-70")}
            />
          <% else %>
            <button
              type="button"
              phx-click="toggle_check"
              phx-value-id={sign.id}
              role="checkbox"
              aria-checked={to_string(sign.checked?)}
              aria-label={sign.text}
              class="-m-3 shrink-0 touch-manipulation p-3"
            >
              <.icon
                name={if sign.checked?, do: "hero-check-circle-solid", else: "hero-stop"}
                class={"size-5 " <> if(sign.checked?, do: "text-success", else: "opacity-70")}
              />
            </button>
          <% end %>
          <span>
            {sign.text}
            <span :if={sign.detail} class="block text-xs opacity-70">{sign.detail}</span>
          </span>
        </li>
      </ul>

      <h3 class="mt-4 text-sm font-semibold">When you're ready: N.A.P.</h3>
      <ol id="nap-steps" class="mt-2 space-y-2">
        <li :for={step <- @steps} class="flex gap-3 text-sm">
          <span class="grid size-8 shrink-0 place-items-center rounded-full bg-primary font-bold text-primary-content">
            {step.letter}
          </span>
          <span>
            <span class="block font-semibold">{step.name}</span>
            <span class="block leading-snug opacity-80">{step.detail}</span>
          </span>
        </li>
      </ol>

      <div :if={@table} id="nap-table" class="mt-4 text-sm">
        <h3 class="font-semibold">The day for {@table.label}</h3>
        <p class="text-xs leading-snug opacity-80">
          {@table.naps} naps · awake {format_duration(elem(@table.wake_window, 0) * 60)}–{format_duration(
            elem(@table.wake_window, 1) * 60
          )} between · {format_duration(elem(@table.daytime_goal, 0) * 60)}–{format_duration(
            elem(@table.daytime_goal, 1) * 60
          )} of daytime
          sleep (not over {format_duration(@table.daytime_cap * 60)}) · bedtime {BedtimePlan.clock(
            elem(@table.bedtime, 0)
          )}–{BedtimePlan.clock(elem(@table.bedtime, 1))} · feeds {@table.feeds}.
        </p>
      </div>

      <details id="nap-tips" class="fold mt-3 text-sm">
        <summary class="cursor-pointer font-medium text-primary">Nap questions</summary>
        <ul class="mt-2 list-disc space-y-1.5 pl-5 leading-snug">
          <li :for={tip <- @tips}>{tip}</li>
        </ul>
      </details>
    </section>
    """
  end

  ## Night mode check-ins ------------------------------------------------------------

  attr :plan, :map, default: nil
  attr :tonight, :map, default: nil
  attr :can_write, :boolean, required: true
  attr :unit_system, :atom, required: true
  attr :tz, :string, required: true
  attr :last_wake, :any, default: nil

  def abcs_idle(assigns) do
    ~H"""
    <div id="night-idle" class="space-y-4">
      <p :if={@last_wake} id="night-last" class="rounded-box bg-[#1b110c] p-3 text-sm">
        {abcs_last_line(@last_wake)}
      </p>

      <h2 class="text-xl font-semibold">
        <%= if @tonight && @tonight.night >= 1 and not @tonight.finished? do %>
          {plan_name(@plan)} · night {@tonight.night} of {@tonight.nights}
        <% else %>
          {plan_name(@plan)}
        <% end %>
      </h2>
      <p class="text-sm opacity-80">{idle_blurb(@plan)}</p>
      <p
        :if={@plan && @plan.definition == :swap && @tonight && @tonight.night >= 1}
        id="night-swap-step"
        class="rounded-box bg-[#1b110c] p-3 text-sm"
      >
        Tonight: {@tonight.step.headline}
      </p>

      <div
        :if={@tonight && Map.get(@tonight, :weaning, []) != []}
        id="night-weaning"
        class="rounded-box bg-[#1b110c] p-3 text-sm"
      >
        <p class="font-medium">Night feeds tonight</p>
        <p :for={feed <- @tonight.weaning} class="tabular-nums opacity-90">
          {BedtimePlan.clock(feed.time)}: {amount_text(feed.amount, @plan.feed_kind, @unit_system)}
        </p>
        <p class="mt-1 text-xs opacity-70">Only once they've been asleep 5–10 minutes.</p>
      </div>

      <div :if={@can_write} class="grid gap-3">
        <button
          id="abcs-put-down"
          type="button"
          phx-click="start_abcs"
          phx-value-kind="bedtime"
          class="rounded-box bg-[#7a3b24] py-6 text-2xl font-semibold text-[#ffe9dc]"
        >
          Put down for the night
        </button>
        <button
          id="abcs-cry"
          type="button"
          phx-click="start_abcs"
          phx-value-kind="waking"
          class="rounded-box border border-[#5a3f31] py-5 text-xl font-semibold"
        >
          They woke and are crying
        </button>
      </div>
      <p :if={!@can_write} class="text-sm opacity-70">
        You can watch a waking here, but only a caregiver can run one.
      </p>
    </div>
    """
  end

  defp plan_name(nil), do: "ABCs of Sleep"

  defp plan_name(%{definition: definition}) when definition in [:abcs, :slip, :swap],
    do: Definitions.short_name(definition)

  defp plan_name(_plan), do: "ABCs of Sleep"

  defp idle_blurb(%{definition: :slip, options: %{"mode" => "full"}}),
    do:
      "Tap when you put them down, and again if they cry. It keeps count of the crying. No visits."

  defp idle_blurb(%{definition: :swap}),
    do:
      "Tap when you put them down. It times how long they take to fall asleep, so progress shows."

  defp idle_blurb(_plan),
    do: "Tap when you put them down, and again if they cry. It times the pop-ins for you."

  defp abcs_last_line(%{outcome: :settled, cry_seconds: seconds}) when is_integer(seconds),
    do:
      "Asleep. Crying took #{if seconds == 0, do: "no time", else: format_duration(seconds)} in total."

  defp abcs_last_line(%{outcome: :settled}), do: "Asleep."
  defp abcs_last_line(_), do: "Stopped."

  attr :wake, :map, required: true
  attr :plan, :map, default: nil
  attr :tonight, :map, default: nil
  attr :bedtime_at, :any, default: nil
  attr :can_write, :boolean, required: true
  attr :now, :any, required: true
  attr :tz, :string, required: true

  def abcs_screen(assigns) do
    night = if assigns.tonight, do: max(assigns.tonight.night, 1), else: 1
    plan = assigns.plan || %Trygg.Sleep.Plan{definition: :abcs}
    definition = plan.definition || :abcs
    state = Checkins.state(assigns.wake.events, assigns.now, Definitions.schedule(plan, night))

    assigns =
      assign(assigns,
        definition: definition,
        state: state,
        seen: length(assigns.wake.events),
        touch: Abcs.touch(night),
        visits?: Definitions.visits?(plan),
        how: visit_text(definition, plan, assigns.tonight, night),
        morning?:
          definition == :abcs and assigns.bedtime_at != nil and
            Abcs.morning_state(assigns.bedtime_at, assigns.now) == :morning,
        due_ms: state.next_due_at && DateTime.to_unix(state.next_due_at) * 1000,
        due?: state.next_due_at && DateTime.compare(assigns.now, state.next_due_at) != :lt
      )

    ~H"""
    <div id="night-step" data-phase={@state.phase} class="space-y-5">
      <div class="flex items-center justify-between gap-3 text-sm">
        <p id="night-method" class="font-medium">
          {plan_name(@plan)}{if @tonight && @tonight.night >= 1, do: " · night #{@tonight.night}"}
        </p>
        <p id="night-started-by" class="opacity-70">
          {if @wake.kind == :bedtime, do: "Put down", else: "Woke"} {clock(@wake.started_at, @tz)}{started_by(
            @wake
          )}
        </p>
      </div>

      <p :if={@morning?} id="abcs-morning" class="rounded-box bg-[#274b36] p-3 text-sm text-[#d6f5e3]">
        It's been 11 hours. Wait for a quiet moment, then go and get them: lights on, lots of praise, feed
        somewhere other than their room.
      </p>

      <%= case @state.phase do %>
        <% :waiting -> %>
          <div class="text-center">
            <p id="abcs-waiting" class="text-2xl font-semibold">Put down. Quiet for now.</p>
            <p class="mt-2 text-sm opacity-80">If they cry, tap below and it starts timing.</p>
          </div>
        <% :crying -> %>
          <div :if={@due_ms} class="text-center">
            <p id="abcs-state" class="text-sm uppercase tracking-wide opacity-70">
              {if @due?,
                do: "Time for pop-in #{@state.pop_ins + 1}",
                else: "Next pop-in (#{@state.pop_ins + 1})"}
            </p>
            <div
              id="night-countdown"
              phx-hook="NightTimer"
              data-ends-at={@due_ms}
              data-elapsed="false"
              class="group"
            >
              <p
                data-night-time
                class="text-7xl font-bold tabular-nums group-data-[elapsed=true]:text-[#ffb27a]"
              >
                {format_countdown(DateTime.diff(@state.next_due_at, @now, :second))}
              </p>
              <p class="mt-1 text-sm opacity-70 group-data-[elapsed=true]:text-[#ffb27a]">
                <span class="group-data-[elapsed=true]:hidden">Wait it out. They may settle by themselves.</span>
                <span class="hidden group-data-[elapsed=true]:inline">
                  Still crying? Go in now.
                </span>
              </p>
            </div>
          </div>
          <div :if={!@due_ms} id="abcs-no-timer" class="text-center">
            <p class="text-2xl font-semibold">
              {if @definition == :slip, do: "Crying. Stay out.", else: "Crying. Wait."}
            </p>
            <p class="mt-2 text-sm opacity-80">
              {if @definition == :slip,
                do: "No visits. They're safe, fed and loved: they're working out how to do this.",
                else: "Give it 5–10 minutes before you go in. They may settle without you."}
            </p>
          </div>
          <p id="abcs-popin-how" class="rounded-box bg-[#1b110c] p-3 text-sm leading-snug">
            {@how}
          </p>
        <% :calming -> %>
          <div class="text-center">
            <p id="abcs-calming" class="text-2xl font-semibold">Calming. Wait.</p>
            <p class="mt-2 text-sm opacity-80">
              Don't go in while they're settling: a pop-in now would only upset them again.
            </p>
          </div>
      <% end %>

      <p id="abcs-cry-total" class="text-center text-sm opacity-80">
        Crying so far:
        <%= if @state.phase == :crying do %>
          <%!-- Ticks on its own while they cry: counts up from a start time that already
               accounts for the crying before now. --%>
          <span
            id="abcs-cry-live"
            phx-hook="Timer"
            data-since={DateTime.to_unix(@now) - @state.cry_seconds}
          >
            {format_duration(@state.cry_seconds)}
          </span>
        <% else %>
          {format_duration(@state.cry_seconds)}
        <% end %>
        <span :if={@visits?}>
          · {if @definition == :swap, do: "times in", else: "pop-ins"}: {@state.pop_ins}
        </span>
      </p>

      <div :if={@can_write} class="grid gap-3">
        <%= case @state.phase do %>
          <% :waiting -> %>
            <button
              id="abcs-record-cry"
              type="button"
              phx-click="record"
              phx-value-kind="cry"
              phx-value-seen={@seen}
              class="rounded-box border border-[#5a3f31] py-5 text-xl font-semibold"
            >
              They started crying
            </button>
          <% :crying -> %>
            <button
              :if={@visits?}
              id="abcs-record-popin"
              type="button"
              phx-click="record"
              phx-value-kind="pop_in"
              phx-value-seen={@seen}
              class="rounded-box bg-[#7a3b24] py-5 text-xl font-semibold text-[#ffe9dc]"
            >
              {if @definition == :swap, do: "I went in", else: "I did a pop-in"}
            </button>
            <button
              id="abcs-record-calm"
              type="button"
              phx-click="record"
              phx-value-kind="calm"
              phx-value-seen={@seen}
              class="rounded-box border border-[#5a3f31] py-4 text-lg"
            >
              They're calming: wait
            </button>
          <% :calming -> %>
            <button
              id="abcs-record-cry"
              type="button"
              phx-click="record"
              phx-value-kind="cry"
              phx-value-seen={@seen}
              class="rounded-box border border-[#5a3f31] py-5 text-xl font-semibold"
            >
              Crying again
            </button>
        <% end %>

        <button
          id="abcs-asleep"
          type="button"
          phx-click="asleep"
          phx-value-seen={@seen}
          class="rounded-box bg-[#274b36] py-5 text-xl font-semibold text-[#d6f5e3]"
        >
          They fell asleep
        </button>
        <button
          id="night-stop"
          type="button"
          phx-click="finish"
          phx-value-outcome="stopped"
          class="py-2 text-sm opacity-70 underline"
        >
          Stop without a result
        </button>
      </div>
    </div>
    """
  end

  defp visit_text(:abcs, _plan, _tonight, night) do
    "#{popin_text(Abcs.touch(night))} Stay 15–20 seconds, say something calm and confident " <>
      "(\"I love you, you can do this, go to sleep\"), then leave."
  end

  defp visit_text(:slip, %{options: %{"mode" => "full"}}, _tonight, _night),
    do:
      "Full plan: you don't go in. If you're worried about their safety, check on the monitor, not in the room."

  defp visit_text(:slip, _plan, _tonight, _night),
    do:
      "A visit is a minute or two: your bedtime words, no picking up, no feeding, no rocking, and leave while they're still awake."

  defp visit_text(:swap, _plan, %{step: %{headline: headline}}, _night),
    do: "Tonight's step: #{headline}"

  defp visit_text(:swap, _plan, _tonight, _night),
    do: "Do what you did at bedtime, a little less than last night."

  defp popin_text(:touch),
    do:
      "Nights 1 and 2: soothing touch: rub their head, pat their body. Don't pick them up. If they're standing you may lay them down once."

  defp popin_text(:voice), do: "From night 3: your voice only. Don't touch them."

  defp started_by(%{started_by: %{first_name: name}}) when is_binary(name) and name != "",
    do: " by #{name}"

  defp started_by(_wake), do: ""

  defp format_countdown(seconds) do
    s = max(seconds, 0)
    "#{div(s, 60)}:#{String.pad_leading("#{rem(s, 60)}", 2, "0")}"
  end

  ## Helpers --------------------------------------------------------------------------

  defp time_or_dash(nil, _tz), do: "—"
  defp time_or_dash(at, tz), do: clock(at, tz)

  defp duration_or_dash(nil), do: "—"
  defp duration_or_dash(seconds), do: format_duration(seconds)
  defp duration_or_dash(nil, _zero?), do: "—"
  defp duration_or_dash(0, true), do: "none"
  defp duration_or_dash(seconds, _zero?), do: format_duration(seconds)

  defp panel_class,
    do: "mb-4 rounded-[var(--radius-card)] border-2 border-base-300 bg-base-200/40 p-4"

  defp heading_class, do: "mb-2 text-sm font-semibold uppercase tracking-wide opacity-70"

  @doc false
  def weaning_table_panel(assigns) do
    ~H"""
    <section :if={@table} id="abcs-weaning-table" class={panel_class()}>
      <h2 class={heading_class()}>Night-weaning plan</h2>
      <div class="overflow-x-auto">
        <table class="w-full min-w-[20rem] text-left text-sm">
          <thead class="text-xs uppercase opacity-70">
            <tr>
              <th class="pb-1 pr-2">Feed</th>
              <th :for={n <- 1..@table.nights} class="pb-1 pr-2">N{n}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @table.rows} class="border-t border-base-300">
              <th scope="row" class="py-1.5 pr-2 font-medium tabular-nums">
                {BedtimePlan.clock(row.time)}
              </th>
              <td :for={amount <- row.amounts} class="py-1.5 pr-2 tabular-nums">
                {if amount, do: amount_cell(amount, @table.kind, @unit_system), else: "none"}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p class="mt-2 text-xs opacity-70">
        By night 5 all night feeds are done. Offer a little extra at daytime feeds as the night ones come down.
        If you keep one night feed, have it before 11 pm.
      </p>
    </section>
    """
  end

  defp amount_cell(amount, :nursing, _system), do: "#{amount} min"
  defp amount_cell(amount, :bottle, system), do: Units.format(amount * 1.0, :volume, system)
end
