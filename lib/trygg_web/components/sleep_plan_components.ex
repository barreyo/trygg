defmodule TryggWeb.SleepPlanComponents do
  @moduledoc """
  The building blocks of the Sleep tab: the phase hero, the "right now" panel
  with the sleepy-cue chips, this week's habits, the C.R.I.E.S. steps, the cue
  guide, the newborn rhythm reference and the roadmap.

  Fed by `Trygg.Sleep.Phase`, `Trygg.Reports.SleepHabits` and
  `Trygg.Sleep.Guide`; the guidance comes from the Taking Cara Babies guides
  (see `Trygg.Sleep.Cue` and `Trygg.Sleep.Cries`).
  """
  use Phoenix.Component

  import TryggWeb.CoreComponents
  import TryggWeb.LogComponents, only: [format_duration: 1, clock: 2]

  alias Trygg.Log.Entry
  alias Trygg.Reports.SleepHabits
  alias Trygg.Sleep.{Assist, Cries, Cue, Guide}

  @doc "A banner on the Sleep tab while a night waking is being worked through."
  attr :wake, :map, required: true
  attr :child, :map, required: true

  def night_wake_banner(assigns) do
    ~H"""
    <.link
      id="night-wake-banner"
      navigate={"/c/#{@child.id}/sleep/night"}
      class="mb-4 flex items-center gap-3 rounded-[var(--radius-card)] border-2 border-warning/50 bg-warning/10 p-4"
    >
      <.icon name="hero-moon" class="size-6 shrink-0 text-warning" />
      <span class="min-w-0 flex-1 leading-snug">
        <span class="block font-semibold">A night waking is in progress</span>
        <span class="block text-sm opacity-80">Open night mode to follow the steps.</span>
      </span>
      <.icon name="hero-arrow-right" class="size-5 shrink-0" />
    </.link>
    """
  end

  ## Hero ----------------------------------------------------------------------

  @doc "The big header: which phase, how far along, and what's next."
  attr :phase, :map, default: nil
  attr :timeline, :list, default: []
  attr :child_name, :string, required: true

  def phase_hero(%{phase: nil} = assigns) do
    ~H"""
    <section id="sleep-hero" class={panel_class()}>
      <p class="text-xs font-semibold uppercase tracking-wide opacity-70">Sleep plan</p>
      <h2 class="text-2xl font-bold leading-tight">Starts once {@child_name} is born</h2>
      <p class="mt-1 opacity-80">
        The plan follows {@child_name}'s age, so it needs a birth date to get going.
      </p>
    </section>
    """
  end

  def phase_hero(assigns) do
    ~H"""
    <section id="sleep-hero" class={panel_class()}>
      <p class="text-xs font-semibold uppercase tracking-wide opacity-70">Sleep plan</p>
      <h2 id="sleep-hero-phase" class="text-2xl font-bold leading-tight">
        {@phase.label} · {week_label(@phase.week)}
      </h2>
      <p id="sleep-hero-blurb" class="mt-1 max-w-prose opacity-80">{blurb(@phase.id)}</p>

      <ol id="sleep-phase-steps" class="mt-4 grid grid-cols-3 gap-2">
        <li
          :for={step <- @timeline}
          id={"sleep-phase-#{step.id}"}
          aria-current={step.state == :current && "step"}
          class={[
            "rounded-field border-2 p-2 text-sm leading-tight",
            step.state == :current && "border-primary bg-primary/10",
            step.state != :current && "border-base-300"
          ]}
        >
          <span class="block font-semibold">{step.label}</span>
          <span class="block text-xs opacity-70">{step_when(step)}</span>
        </li>
      </ol>

      <p :if={@phase.next} id="sleep-hero-next" class="mt-3 text-sm opacity-80">
        {@phase.next.label} starts {Calendar.strftime(@phase.next.on, "%b %-d")}, {time_to_go(
          @phase.next.in_days
        )}.
      </p>
    </section>
    """
  end

  ## Right now -----------------------------------------------------------------

  @doc """
  Whether they're asleep or awake, the cue chips, and the button to start or
  stop. `running` is the running sleep entry (or `nil`), `last` the latest sleep.
  """
  attr :running, :any, default: nil
  attr :last, :any, default: nil
  attr :pending_cue, :string, default: nil
  attr :can_write, :boolean, required: true
  attr :tz, :string, required: true
  attr :track_assist, :boolean, default: false

  def right_now(assigns) do
    ~H"""
    <section id="sleep-right-now" class={panel_class()}>
      <h2 class={heading_class()}>Right now</h2>

      <%= if @running do %>
        <p class="text-sm opacity-70">Asleep since {clock(@running.started_at, @tz)}</p>
        <p
          id={"sleep-timer-#{@running.id}"}
          phx-hook="Timer"
          data-since={DateTime.to_unix(@running.started_at)}
          class="text-4xl font-bold tabular-nums"
        >
          {format_duration(Entry.duration_seconds(@running))}
        </p>

        <div :if={@can_write}>
          <.cue_chips selected={@running.data["cue"]} label="How did they look going down?" />
          <.assist_form :if={@track_assist} running={@running} />
          <.button
            id="stop-sleep"
            type="button"
            variant="primary"
            class="mt-4 w-full"
            phx-click="stop_sleep"
          >
            <.icon name="hero-stop" class="size-5" /> Stop sleep
          </.button>
        </div>
      <% else %>
        <p class="text-sm opacity-70">{awake_line(@last, @tz)}</p>
        <div :if={@can_write}>
          <.cue_chips selected={@pending_cue} label="Showing cues? Tap what you see, then start." />
          <.button
            id="start-sleep"
            type="button"
            variant="primary"
            class="mt-4 w-full"
            phx-click="start_sleep"
          >
            <.icon name="hero-moon" class="size-5" /> Start sleep
          </.button>
        </div>
      <% end %>
    </section>
    """
  end

  attr :running, :map, required: true

  defp assist_form(assigns) do
    assigns =
      assign(
        assigns,
        :form,
        to_form(
          %{
            "assist" => to_string(assigns.running.data["assist"] || ""),
            "settle" => to_string(assigns.running.data["settle_minutes"] || "")
          },
          as: :fall
        )
      )

    ~H"""
    <.form for={@form} id="assist-form" phx-change="set_assist" class="mt-3 space-y-2">
      <.input
        field={@form[:assist]}
        id="assist-select"
        type="select"
        label="How did they fall asleep?"
        prompt="Not noted"
        options={for {level, text} <- Assist.levels(), do: {"#{level}. #{text}", level}}
      />
      <.input
        field={@form[:settle]}
        id="settle-select"
        type="select"
        label="How long did it take?"
        prompt="Not noted"
        options={for {minutes, label} <- Assist.settle_options(), do: {label, minutes}}
      />
    </.form>
    """
  end

  @doc """
  Three tap-to-toggle chips for the sleepy cue (tired / ready / overtired).
  Each pushes `set_cue` with the cue id; `selected` is the one currently set.
  """
  attr :id, :string, default: "cue-chips"
  attr :selected, :string, default: nil
  attr :label, :string, required: true

  def cue_chips(assigns) do
    ~H"""
    <div id={@id} class="mt-3 space-y-1.5">
      <span class="block text-sm opacity-80">{@label}</span>
      <div class="grid grid-cols-3 gap-2">
        <.button
          :for={cue <- Cue.all()}
          id={"cue-chip-#{cue.id}"}
          type="button"
          variant={if @selected == cue.id, do: "primary"}
          phx-click="set_cue"
          phx-value-cue={cue.id}
          aria-pressed={to_string(@selected == cue.id)}
        >
          {cue.label}
        </.button>
      </div>
    </div>
    """
  end

  ## Schedule and insights ----------------------------------------------------

  @doc """
  Today's whole sleep day as a timeline: what happened, what's running, what's
  predicted. `plan` is a `Trygg.Reports.DayPlan.build/3` map.
  """
  attr :plan, :map, required: true
  attr :tz, :string, required: true

  def schedule_panel(assigns) do
    ~H"""
    <section id="sleep-schedule" class={panel_class()}>
      <h2 class={heading_class()}>Today's schedule</h2>

      <%= if @plan.items == [] do %>
        <p id="sleep-schedule-empty" class="text-sm opacity-80">
          Log a sleep or two and today's naps and bedtime show up here.
        </p>
      <% else %>
        <ol class="mt-1">
          <li
            :for={{item, i} <- Enum.with_index(@plan.items)}
            id={"plan-#{item.id}"}
            data-state={item.state}
            class="flex gap-3"
          >
            <div class="flex flex-col items-center">
              <span class={[
                "grid size-8 shrink-0 place-items-center rounded-full border-2",
                dot_class(item.state)
              ]}>
                <.icon name={dot_icon(item)} class="size-4" />
              </span>
              <span
                :if={i < length(@plan.items) - 1}
                class="w-px flex-1 bg-base-300"
                aria-hidden="true"
              ></span>
            </div>
            <div class={["min-w-0 flex-1 pb-4", item.state == :done && "opacity-70"]}>
              <div class="flex items-baseline justify-between gap-3">
                <p class="font-semibold leading-tight">{item_title(item)}</p>
                <p class="shrink-0 text-sm tabular-nums">{item_time(item, @tz)}</p>
              </div>
              <p :if={item_sub(item)} class="text-sm leading-snug opacity-80">{item_sub(item)}</p>
              <p :if={item_note(item)} class="text-xs leading-snug opacity-70">{item_note(item)}</p>
            </div>
          </li>
        </ol>
        <p id="sleep-schedule-total" class="text-xs opacity-70">
          Daytime sleep so far: {format_duration(@plan.day_sleep_seconds)}.
          Upcoming times are estimates from today's conditions.
        </p>
      <% end %>
    </section>
    """
  end

  @doc "Insights and suggestions from `Trygg.Sleep.Coach`."
  attr :insights, :list, required: true

  def insights_panel(assigns) do
    ~H"""
    <section id="sleep-insights" class={panel_class()}>
      <h2 class={heading_class()}>Insights and suggestions</h2>

      <p :if={@insights == []} id="sleep-insights-empty" class="text-sm opacity-80">
        Nothing to flag right now. Things look on track.
      </p>

      <ul class="space-y-2">
        <li
          :for={insight <- @insights}
          id={"insight-#{insight.id}"}
          data-tone={insight.tone}
          class={[
            "flex items-start gap-3 rounded-box border-2 p-3",
            insight_class(insight.tone)
          ]}
        >
          <.icon name={insight_icon(insight.tone)} class="mt-0.5 size-5 shrink-0" />
          <div class="min-w-0">
            <p class="font-semibold leading-tight">{insight.title}</p>
            <p class="text-sm leading-snug opacity-90">{insight.detail}</p>
          </div>
        </li>
      </ul>
    </section>
    """
  end

  ## Overnight ------------------------------------------------------------------

  @doc """
  How the last few nights went. `nights` is a `Trygg.Reports.Nights.summarize/3`
  map.
  """
  attr :nights, :map, required: true
  attr :tz, :string, required: true

  def overnight_panel(assigns) do
    assigns = assign(assigns, :longest, longest_seconds(assigns.nights))

    ~H"""
    <section id="sleep-overnight" class={panel_class()}>
      <h2 class={heading_class()}>Overnight</h2>

      <%= if @nights.nights == [] do %>
        <p id="sleep-overnight-empty" class="text-sm opacity-80">
          Log a night or two and you'll see the longest stretches, wakings and feeds here.
        </p>
      <% else %>
        <p class="mb-2 text-sm opacity-70">
          Last night, {Calendar.strftime(local(@nights.last.wake, @tz), "%a %-d %b")}
        </p>
        <dl class="grid grid-cols-2 gap-2">
          <.stat id="night-slept" label="Slept" value={format_duration(@nights.last.asleep_seconds)} />
          <.stat
            id="night-longest"
            label="Longest sleep"
            value={format_duration(@nights.last.longest_sleep_seconds)}
          />
          <.stat id="night-wakings" label="Wakings" value={@nights.last.wakings} />
          <.stat id="night-feeds" label="Night feeds" value={@nights.last.feeds} />
        </dl>

        <ol id="overnight-bars" class="mt-4 space-y-1.5" aria-label="Longest unbroken sleep, by night">
          <li
            :for={night <- Enum.reverse(@nights.nights)}
            id={"night-#{night.date}"}
            class="flex items-center gap-2 text-sm"
          >
            <span class="w-9 shrink-0 opacity-70">
              {Calendar.strftime(local(night.wake, @tz), "%a")}
            </span>
            <span class="h-3 flex-1 overflow-hidden rounded-full bg-base-300">
              <span
                class="block h-full rounded-full bg-primary"
                style={"width: #{bar_percent(night.longest_sleep_seconds, @longest)}%"}
              ></span>
            </span>
            <span class="w-14 shrink-0 text-right tabular-nums">
              {format_duration(night.longest_sleep_seconds)}
            </span>
          </li>
        </ol>
        <p class="mt-1 text-xs opacity-70">Longest unbroken sleep each night.</p>

        <p :if={trend_line(@nights)} id="overnight-trend" class="mt-3 text-sm">
          {trend_line(@nights)}
        </p>
        <p :if={@nights.best_baseline_seconds} id="overnight-baseline" class="mt-3 text-sm">
          Best baseline between feeds:
          <span class="font-semibold">{format_duration(@nights.best_baseline_seconds)}</span>
          <span class="block text-xs opacity-70">
            The longest they've gone on at least two of these nights. It's where stretching night feeds
            would start from about 13 weeks; for now it's just worth knowing.
          </span>
        </p>
      <% end %>
    </section>
    """
  end

  defp longest_seconds(%{nights: []}), do: 1

  defp longest_seconds(%{nights: nights}),
    do: nights |> Enum.map(& &1.longest_sleep_seconds) |> Enum.max() |> max(1)

  defp bar_percent(seconds, longest), do: round(seconds / longest * 100)

  defp local(%DateTime{} = at, tz), do: DateTime.shift_zone!(at, tz)

  defp trend_line(%{trend_seconds: nil}), do: nil

  defp trend_line(%{trend_seconds: seconds}) when abs(seconds) < 600,
    do: "Longest sleeps are steady compared with the 3 nights before."

  defp trend_line(%{trend_seconds: seconds}) when seconds > 0,
    do: "Longest sleeps are up about #{format_duration(seconds)} on the 3 nights before."

  defp trend_line(%{trend_seconds: seconds}),
    do: "Longest sleeps are down about #{format_duration(abs(seconds))} on the 3 nights before."

  ## Habits --------------------------------------------------------------------

  @doc "This week's cue and feed → sleep numbers (`Trygg.Reports.SleepHabits`)."
  attr :habits, :map, required: true

  def habits_panel(assigns) do
    ~H"""
    <section id="sleep-habits" class={panel_class()}>
      <h2 class={heading_class()}>This week</h2>

      <%= if @habits.week.sleeps == 0 do %>
        <p id="sleep-habits-empty" class="text-sm opacity-80">
          Log a few sleeps and the patterns show up here.
        </p>
      <% else %>
        <dl class="grid grid-cols-2 gap-2">
          <.stat id="stat-sleeps" label="Sleeps" value={@habits.week.sleeps} />
          <.stat id="stat-cued" label="With a cue noted" value={@habits.week.cued} />
          <.stat id="stat-overtired" label="Started overtired" value={@habits.week.overtired} />
          <.stat
            id="stat-fed-to-sleep"
            label={"Within #{minutes()} of a feed"}
            value={fed_value(@habits.week)}
          />
        </dl>

        <p :if={windows_line(@habits)} id="sleep-habits-windows" class="mt-3 text-sm">
          {windows_line(@habits)}
        </p>
        <p :if={@habits.week.cued == 0} id="sleep-habits-cue-hint" class="mt-3 text-sm opacity-80">
          Tap a cue before you start a sleep and this will show how long they're usually awake when they're ready.
        </p>
        <p :if={@habits.week.measured > 0} class="mt-3 text-xs opacity-70">
          Just a pattern to see: feeding to sleep is normal at this age.
        </p>
      <% end %>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat(assigns) do
    ~H"""
    <div id={@id} class="rounded-field bg-base-100 p-3">
      <dt class="text-xs opacity-70 leading-tight">{@label}</dt>
      <dd class="mt-1 text-2xl font-bold tabular-nums whitespace-nowrap">{@value}</dd>
    </div>
    """
  end

  ## Reference content ---------------------------------------------------------

  @doc "The five C.R.I.E.S. steps for calming a crying newborn."
  def cries_panel(assigns) do
    assigns = assign(assigns, :steps, Cries.steps())

    ~H"""
    <section id="sleep-cries" class={panel_class()}>
      <h2 class={heading_class()}>When they cry: C.R.I.E.S.</h2>
      <p class="mb-3 text-sm opacity-80">
        A calming order to try, from the Taking Cara Babies newborn guidance.
      </p>
      <ol id="cries-steps" class="space-y-3">
        <li :for={step <- @steps} id={"cries-#{String.downcase(step.letter)}"} class="flex gap-3">
          <span class="grid size-9 shrink-0 place-items-center rounded-full bg-primary text-lg font-bold text-primary-content">
            {step.letter}
          </span>
          <div class="min-w-0">
            <p class="font-semibold leading-tight">{step.name}</p>
            <p class="text-sm leading-snug opacity-80">{step.detail}</p>
          </div>
        </li>
      </ol>
      <p class="mt-4 text-xs opacity-70">
        Hungry, wet or too warm? Check those first. If the crying seems unusual, or they have a fever,
        call your pediatrician.
      </p>
    </section>
    """
  end

  @doc "What tired, ready and overtired look like."
  def cue_guide(assigns) do
    ~H"""
    <section id="sleep-cue-guide" class={panel_class()}>
      <h2 class={heading_class()}>Sleepy cues</h2>
      <dl class="space-y-3">
        <div :for={cue <- Cue.all()} id={"cue-guide-#{cue.id}"}>
          <dt class="font-semibold">{cue.title}</dt>
          <dd class="text-sm opacity-80">{Enum.join(cue.signs, " · ")}</dd>
        </div>
      </dl>
      <p class="mt-3 text-xs opacity-70">
        Newborns: start a nap as soon as the cues show. Overtired babies often seem wired, not sleepy.
      </p>
    </section>
    """
  end

  @doc "The newborn master schedule, as a rhythm to practise."
  def rhythm_reference(assigns) do
    assigns =
      assign(assigns, principles: Guide.principles(), schedule: Guide.master_schedule())

    ~H"""
    <section id="sleep-rhythm" class={panel_class()}>
      <h2 class={heading_class()}>A newborn day</h2>
      <ul class="mb-3 list-disc space-y-1 pl-5 text-sm">
        <li :for={line <- @principles}>{line}</li>
      </ul>
      <table id="master-schedule" class="w-full text-sm">
        <tbody>
          <tr :for={{time, activity} <- @schedule} class="border-t border-base-300">
            <th scope="row" class="py-1.5 pr-3 text-left font-medium whitespace-nowrap">{time}</th>
            <td class={[activity =~ "Sleeping" && "text-primary font-medium"]}>{activity}</td>
          </tr>
        </tbody>
      </table>
      <p class="mt-3 text-xs opacity-70">
        A routine to practise, not a schedule to follow exactly.
      </p>
    </section>
    """
  end

  @doc "Every phase with what it's about; the current one is highlighted."
  attr :timeline, :list, required: true

  def roadmap(assigns) do
    assigns = assign(assigns, :topics, &Guide.topics/1)

    ~H"""
    <section id="sleep-roadmap" class={panel_class()}>
      <h2 class={heading_class()}>The road ahead</h2>
      <ol class="space-y-4">
        <li :for={step <- @timeline} id={"roadmap-#{step.id}"}>
          <p class="font-semibold">
            {step.label}
            <span class="font-normal text-sm opacity-70">· {step_when(step)}</span>
          </p>
          <ul class="mt-1 list-disc space-y-1 pl-5 text-sm leading-snug opacity-90">
            <li :for={line <- @topics.(step.id)}>{line}</li>
          </ul>
        </li>
      </ol>
    </section>
    """
  end

  ## Copy ----------------------------------------------------------------------

  defp panel_class,
    do: "mb-4 rounded-[var(--radius-card)] border-2 border-base-300 bg-base-200/40 p-4"

  defp heading_class, do: "mb-2 text-sm font-semibold uppercase tracking-wide opacity-70"

  defp dot_class(:done), do: "border-base-300 bg-base-200"
  defp dot_class(:now), do: "border-primary bg-primary text-primary-content"
  defp dot_class(:due), do: "border-warning bg-warning/20 text-warning"
  defp dot_class(:upcoming), do: "border-base-300 border-dashed"

  defp dot_icon(%{state: :done, kind: :wake}), do: "hero-sun"
  defp dot_icon(%{state: :done}), do: "hero-check"
  defp dot_icon(%{kind: :wake}), do: "hero-sun"
  defp dot_icon(%{kind: :bed}), do: "hero-moon"
  defp dot_icon(%{state: :due}), do: "hero-bell-alert"
  defp dot_icon(%{state: :now}), do: "hero-moon"
  defp dot_icon(_item), do: "hero-clock"

  defp item_title(%{kind: :wake, estimate?: true}), do: "Usual wake-up"
  defp item_title(%{kind: :wake}), do: "Woke up"
  defp item_title(%{kind: :nap, ordinal: n}), do: "Nap #{n}"
  defp item_title(%{kind: :bed, state: :done}), do: "Bedtime"
  defp item_title(%{kind: :bed}), do: "Bedtime"

  defp item_time(%{kind: :nap, state: :now} = item, tz), do: "since " <> clock(item.start, tz)

  defp item_time(%{kind: :nap, state: :done, end: %DateTime{} = ended} = item, tz),
    do: clock(item.start, tz) <> "–" <> clock(ended, tz)

  defp item_time(%{range: %{from: from, to: to}}, tz), do: clock(from, tz) <> "–" <> clock(to, tz)
  defp item_time(%{state: :due}, _tz), do: "now"
  defp item_time(%{estimate?: true} = item, tz), do: "about " <> clock(item.start, tz)
  defp item_time(item, tz), do: clock(item.start, tz)

  defp item_sub(%{kind: :nap, state: :now, seconds: s}), do: "Asleep #{format_duration(s)} so far"

  defp item_sub(%{kind: :nap, state: :due}),
    do: "Window is open: start settling at the first sleepy cues"

  defp item_sub(%{kind: :nap, state: :done} = item),
    do: join_parts([format_duration(item.seconds), awake_part(item)])

  defp item_sub(%{kind: :nap, state: :upcoming} = item),
    do: join_parts([length_part(item), awake_part(item)])

  defp item_sub(%{kind: :bed, awake_before: awake}) when is_integer(awake),
    do: "#{format_duration(awake)} awake before bed"

  defp item_sub(_item), do: nil

  defp item_note(%{kind: :bed, shifted_by_seconds: shift}) when is_integer(shift) and shift > 0,
    do: "Earlier than usual: less daytime sleep so far today"

  defp item_note(%{estimate?: true, source: source}) when not is_nil(source),
    do: source_label(source)

  defp item_note(_item), do: nil

  defp length_part(%{seconds: s}) when is_integer(s), do: "about #{format_duration(s)} long"
  defp length_part(_item), do: nil

  defp awake_part(item),
    do: item.awake_before && "after #{format_duration(item.awake_before)} awake"

  defp join_parts(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.join(" · ") |> presence()

  defp presence(""), do: nil
  defp presence(s), do: s

  defp source_label(:history), do: "Based on their last couple of weeks"
  defp source_label(:blended), do: "A blend of their pattern and what's typical for their age"
  defp source_label(:age_prior), do: "Typical for their age so far"
  defp source_label(_), do: nil

  defp insight_class(:watch), do: "border-warning/50 bg-warning/10"
  defp insight_class(:suggest), do: "border-primary/40 bg-primary/10"
  defp insight_class(_), do: "border-base-300 bg-base-100"

  defp insight_icon(:watch), do: "hero-exclamation-triangle"
  defp insight_icon(:suggest), do: "hero-light-bulb"
  defp insight_icon(_), do: "hero-information-circle"

  defp week_label(0), do: "first week"
  defp week_label(week), do: "week #{week}"

  defp blurb(:newborn),
    do:
      "Feed about every 2.5–3 hours, practise feed → awake time → sleep when it's easy, and catch sleepy cues before they tip into overtired."

  defp blurb(:foundations),
    do:
      "Sleep cycles are maturing and wake windows are getting longer. Keep watching both the cues and the clock."

  defp blurb(_phase), do: "Keep watching cues and the clock."

  defp step_when(%{state: :current}), do: "now"
  defp step_when(%{starts_on: on}), do: "from " <> Calendar.strftime(on, "%b %-d")

  defp awake_line(%Entry{ended_at: %DateTime{} = at}, tz), do: "Awake since #{clock(at, tz)}"
  defp awake_line(_last, _tz), do: "No sleep logged yet"

  defp windows_line(%{cue_windows: windows}) when map_size(windows) == 0, do: nil

  defp windows_line(%{cue_windows: windows}) do
    parts =
      for cue <- Cue.all(), %{median_seconds: seconds} <- [windows[cue.id]] do
        "#{cue.label} #{format_duration(seconds)}"
      end

    "Typical time awake before sleep: " <> Enum.join(parts, " · ")
  end

  defp fed_value(%{measured: 0}), do: "—"
  defp fed_value(%{fed_to_sleep: n, measured: m}), do: "#{n} of #{m}"

  defp minutes, do: "#{div(SleepHabits.fed_to_sleep_seconds(), 60)} min"

  defp time_to_go(days) when days >= 14, do: "about #{div(days, 7)} weeks to go"
  defp time_to_go(1), do: "1 day to go"
  defp time_to_go(days), do: "#{days} days to go"
end
