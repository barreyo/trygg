defmodule TryggWeb.SleepToolkitComponents do
  @moduledoc """
  The panels of the Sleep toolkit page: how they fall asleep, bedtime planning
  with the guide's day, the night-feed plan and the checklists. Fed by
  `Trygg.Reports.sleep_toolkit/4`.
  """
  use Phoenix.Component

  import TryggWeb.CoreComponents
  import TryggWeb.LogComponents, only: [format_duration: 1, clock: 2]

  alias Trygg.Sleep.{Assist, BedtimePlan, NightFeeds, PowerTools, SafeSleep}
  alias Trygg.Units

  @doc "Links between the Sleep tab's pages."
  attr :current, :atom, required: true, values: [:today, :toolkit, :plan, :playbooks, :night]
  attr :child, :map, required: true

  def sleep_subnav(assigns) do
    ~H"""
    <nav id="sleep-subnav" class="mb-4 grid grid-cols-5 gap-1.5" aria-label="Sleep sections">
      <.button
        id="subnav-today"
        navigate={"/c/#{@child.id}/sleep"}
        size="sm"
        class="w-full px-1"
        variant={if @current == :today, do: "primary"}
        aria-current={@current == :today && "page"}
      >
        Today
      </.button>
      <.button
        id="subnav-toolkit"
        navigate={"/c/#{@child.id}/sleep/toolkit"}
        size="sm"
        class="w-full px-1"
        variant={if @current == :toolkit, do: "primary"}
        aria-current={@current == :toolkit && "page"}
      >
        Toolkit
      </.button>
      <.button
        id="subnav-plan"
        navigate={"/c/#{@child.id}/sleep/plan"}
        size="sm"
        class="w-full px-1"
        variant={if @current == :plan, do: "primary"}
        aria-current={@current == :plan && "page"}
      >
        Plan
      </.button>
      <.button
        id="subnav-playbooks"
        navigate={"/c/#{@child.id}/sleep/playbooks"}
        size="sm"
        class="w-full px-1"
        variant={if @current == :playbooks, do: "primary"}
        aria-current={@current == :playbooks && "page"}
      >
        Fixes
      </.button>
      <.button
        id="subnav-night"
        navigate={"/c/#{@child.id}/sleep/night"}
        size="sm"
        class="w-full px-1"
        variant={if @current == :night, do: "primary"}
        aria-current={@current == :night && "page"}
      >
        <.icon name="hero-moon" class="size-4" />Night
      </.button>
    </nav>
    """
  end

  ## How they fall asleep --------------------------------------------------------

  attr :falling_asleep, :map, required: true
  attr :phase, :map, default: nil

  def falling_asleep_panel(assigns) do
    ~H"""
    <section id="toolkit-falling-asleep" class={panel_class()}>
      <h2 class={heading_class()}>How they fall asleep</h2>

      <%= if @phase && @phase.id == :newborn do %>
        <p id="falling-asleep-locked" class="text-sm opacity-80">
          Tracking opens at 13 weeks. For now, feeding, rocking or holding them to sleep is normal and
          nothing to work on.
        </p>
      <% else %>
        <%= if @falling_asleep.tracked == 0 do %>
          <p id="falling-asleep-empty" class="text-sm opacity-80">
            When a sleep is running, note how they fell asleep on the Sleep tab. The weekly picture shows here.
          </p>
        <% else %>
          <ol id="falling-asleep-weeks" class="space-y-1.5" aria-label="Average level by week">
            <li
              :for={week <- @falling_asleep.weeks}
              id={"fa-week-#{week.from}"}
              class="flex items-center gap-2 text-sm"
            >
              <span class="w-14 shrink-0 opacity-70">{Calendar.strftime(week.from, "%-d %b")}</span>
              <span class="h-3 flex-1 overflow-hidden rounded-full bg-base-300">
                <span
                  :if={week.mean_level}
                  class="block h-full rounded-full bg-primary"
                  style={"width: #{round(week.mean_level / 9 * 100)}%"}
                ></span>
              </span>
              <span class="w-16 shrink-0 text-right tabular-nums">{week_value(week)}</span>
            </li>
          </ol>
          <p class="mt-1 text-xs opacity-70">
            Average level of 9 (1 = fed or rocked to sleep, 9 = fell asleep alone), by week.
          </p>

          <p id="falling-asleep-summary" class="mt-3 text-sm">{summary_line(@falling_asleep)}</p>
          <p :if={next_step(@falling_asleep)} id="falling-asleep-next" class="mt-2 text-sm">
            {next_step(@falling_asleep)}
          </p>
        <% end %>

        <details id="assist-scale" class="fold mt-3 text-sm">
          <summary class="cursor-pointer font-medium text-primary">
            The scale, from most to least help
          </summary>
          <ol class="mt-2 space-y-1">
            <li :for={{level, text} <- Assist.levels()} id={"assist-level-#{level}"}>
              <span class="font-semibold">{level}.</span> {text}
            </li>
          </ol>
          <p class="mt-2 text-xs opacity-70">
            Start where you are and move down one step when you can. If a step isn't working after
            10–15 minutes, go back up and try again tomorrow.
          </p>
        </details>
      <% end %>
    </section>
    """
  end

  defp week_value(%{mean_level: nil}), do: "—"
  defp week_value(%{mean_level: level, n: n}), do: "#{format_level(level)} · #{n}"

  defp format_level(level), do: :erlang.float_to_binary(level * 1.0, decimals: 1)

  defp summary_line(%{this_week: week, trend: trend}) do
    parts =
      [
        week.n > 0 &&
          "This week: average level #{format_level(week.mean_level)} over #{week.n} sleeps",
        week.median_settle &&
          "usually settling in about #{week.median_settle} min",
        week.independent_share && week.independent_share > 0 &&
          "#{round(week.independent_share * 100)}% at level 8–9",
        trend_part(trend)
      ]
      |> Enum.filter(& &1)

    if parts == [], do: "Nothing tracked this week yet.", else: Enum.join(parts, " · ") <> "."
  end

  defp trend_part(nil), do: nil
  defp trend_part(t) when t >= 0.3, do: "up #{format_level(t)} on the week before"
  defp trend_part(t) when t <= -0.3, do: "down #{format_level(abs(t))} on the week before"
  defp trend_part(_), do: "steady on the week before"

  defp next_step(%{latest: latest, this_week: week}) do
    level = (week.mean_level && round(week.mean_level)) || latest

    with level when is_integer(level) <- level,
         step when is_integer(step) <- Assist.next_step(level) do
      "A step to try next (level #{step}): #{Assist.label(step)}."
    else
      _ -> nil
    end
  end

  ## Bedtime plan -----------------------------------------------------------------

  attr :plan, :map, default: nil
  attr :table, :map, default: nil
  attr :guide_day, :map, default: nil
  attr :tz, :string, required: true

  def bedtime_panel(%{plan: nil} = assigns) do
    ~H"""
    <section id="toolkit-bedtime" class={panel_class()}>
      <h2 class={heading_class()}>Bedtime plan</h2>
      <p id="bedtime-locked" class="text-sm opacity-80">
        Bedtime planning opens at 13 weeks. Until then, bedtime follows the last sleep and the day, and
        often falls late in the evening.
      </p>
    </section>
    """
  end

  def bedtime_panel(assigns) do
    {lo, hi} = assigns.plan.window
    assigns = assign(assigns, lo: BedtimePlan.clock(lo), hi: BedtimePlan.clock(hi))

    ~H"""
    <section id="toolkit-bedtime" class={panel_class()}>
      <h2 class={heading_class()}>Bedtime plan</h2>
      <p class="text-sm">
        Aim for <span class="font-semibold">{@lo}–{@hi}</span>: the window when babies fall asleep most
        easily and stay asleep longest.
      </p>

      <p id="bedtime-status" class="mt-2 text-sm">{status_line(@plan)}</p>

      <ol :if={@plan.steps != []} id="bedtime-steps" class="mt-2 space-y-1 text-sm">
        <li :for={step <- @plan.steps} id={"bedtime-step-#{step.evening}"}>
          <span class="opacity-70">{step_label(step.evening)}</span>
          <span class="font-semibold tabular-nums">{BedtimePlan.clock(step.minutes)}</span>
        </li>
      </ol>

      <p :if={@plan.last_nap_by} id="bedtime-last-nap" class="mt-3 text-sm">
        For that bedtime, the last nap should end between
        <span class="font-semibold tabular-nums">
          {BedtimePlan.clock(elem(@plan.last_nap_by, 0))}–{BedtimePlan.clock(
            elem(@plan.last_nap_by, 1)
          )}
        </span>
        (100–120 minutes before bed).
      </p>

      <details :if={@guide_day} id="guide-day" class="fold mt-4">
        <summary class="cursor-pointer text-sm font-semibold text-primary">
          A day by the guide ({@table.label})
        </summary>
        <p class="mt-1 text-xs opacity-70">
          {@table.naps} naps, awake {format_duration(elem(@table.wake_window, 0) * 60)}–{format_duration(
            elem(@table.wake_window, 1) * 60
          )} between, and {format_duration(elem(@table.daytime_goal, 0) * 60)}–{format_duration(
            elem(@table.daytime_goal, 1) * 60
          )} of daytime sleep (not over {format_duration(@table.daytime_cap * 60)}). Feeds {@table.feeds}.
        </p>
        <table class="mt-2 w-full text-sm">
          <tbody>
            <tr
              :for={item <- @guide_day.items}
              id={"guide-#{item.kind}-#{item.ordinal || "bed"}"}
              class="border-t border-base-300"
            >
              <th scope="row" class="py-1.5 pr-3 text-left font-medium whitespace-nowrap">
                {guide_label(item)}
              </th>
              <td class="tabular-nums">{guide_time(item, @tz)}</td>
            </tr>
          </tbody>
        </table>
        <p :for={note <- @guide_day.notes} class="mt-1 text-xs opacity-70">{guide_note(note)}</p>
        <p class="mt-2 text-xs opacity-70">
          Built from this morning's wake-up. A routine to practise, not a schedule to follow exactly.
        </p>
      </details>
    </section>
    """
  end

  defp status_line(%{status: :unknown}),
    do: "Log a few bedtimes and this shows how they compare with the window."

  defp status_line(%{status: :within, usual: usual}),
    do: "Their usual bedtime, #{BedtimePlan.clock(usual)}, is inside the window. Keep it."

  defp status_line(%{status: :early, usual: usual}) do
    "Their usual bedtime, #{BedtimePlan.clock(usual)}, is earlier than the window. That's fine when the last nap ended early; an early bedtime makes up for lost sleep."
  end

  defp status_line(%{status: :late, usual: usual, tonight: tonight}) do
    "Their usual bedtime, #{BedtimePlan.clock(usual)}, is later than the window. Move it earlier by 10–15 minutes each evening, starting with #{BedtimePlan.clock(tonight)} tonight."
  end

  defp step_label(1), do: "Tonight"
  defp step_label(n), do: "Evening #{n}"

  defp guide_label(%{kind: :nap, ordinal: n}), do: "Nap #{n}"
  defp guide_label(%{kind: :bed}), do: "Bedtime"

  defp guide_time(%{kind: :bed, start: at}, tz), do: clock(at, tz)
  defp guide_time(%{start: from, end: to}, tz), do: clock(from, tz) <> "–" <> clock(to, tz)

  defp guide_note(:late_naps),
    do: "The naps run late for the bedtime window: shorten the last nap or wake from it sooner."

  defp guide_note(:early_bedtime),
    do: "An early bedtime, because the day ended early. Earlier is fine when naps were short."

  ## Night feeds ------------------------------------------------------------------

  attr :gates, :map, required: true
  attr :plan, :map, required: true
  attr :unit_system, :atom, required: true
  attr :tz, :string, required: true
  attr :can_write, :boolean, required: true
  attr :child_id, :integer, required: true
  attr :typical, :map, default: nil

  def night_feeds_panel(assigns) do
    ~H"""
    <section id="toolkit-night-feeds" class={panel_class()}>
      <h2 class={heading_class()}>Night feeds</h2>

      <ul id="night-feed-gates" class="space-y-2 text-sm">
        <li id="gate-age" class="flex gap-2">
          <.gate_icon ok={match?({:ok, _}, @gates.age)} />
          <span>{age_text(@gates.age)}</span>
        </li>
        <li id="gate-weight" class="flex gap-2">
          <.gate_icon ok={@gates.weight == :ok} />
          <span>{@gates.weight_detail}
          <.link navigate={"/c/#{@child_id}/vitals"} class="text-primary underline">Vitals</.link></span>
        </li>
        <li id="gate-clearance" class="flex gap-2">
          <.gate_icon ok={not is_nil(@gates.clearance)} />
          <span>
            <%= if @gates.clearance do %>
              Pediatrician OK recorded {Calendar.strftime(@gates.clearance, "%b %-d")}.
            <% else %>
              Talk to your pediatrician before cutting any night feed, then record it here.
            <% end %>
            <.button
              :if={@can_write}
              id="toggle-night-weaning-clearance"
              type="button"
              size="xs"
              class="ml-1"
              phx-click="set_clearance"
              phx-value-kind="night_weaning"
              data-confirm={clearance_confirm(@gates.clearance)}
            >
              {if @gates.clearance, do: "Clear", else: "My pediatrician said it's OK"}
            </.button>
          </span>
        </li>
      </ul>

      <%= if @gates.ready? do %>
        <.night_feed_plan plan={@plan} unit_system={@unit_system} tz={@tz} />
      <% else %>
        <p id="night-feeds-closed" class="mt-3 text-xs opacity-70">
          The plan opens once all three are in place. Until then, feed them when they're hungry.
        </p>
      <% end %>

      <p class="mt-3 text-xs opacity-70">
        Most healthy babies can go at least 4 hours at night if they feed well every 2–4 hours by day.
        The goal is one night feed by the end of the fourth month. Not medical advice.
      </p>

      <p :if={@typical} id="night-feeds-typical" class="mt-3 text-sm">
        At {@typical.label}, <span class="font-semibold">{@typical.average}</span>
        night feeds is typical. Some babies need none ({@typical.low}), and up to {@typical.high} isn't unusual.
        Feeding more at night is only a problem if it's a problem for you.
      </p>

      <details id="night-feed-rules" class="fold mt-3">
        <summary class="cursor-pointer text-sm font-semibold text-primary">
          Which night wakings get a feed
        </summary>
        <p class="mt-1 text-xs opacity-70">
          For when they fall asleep on their own and you're deciding what to do at 2 a.m.
        </p>
        <ul class="mt-2 list-disc space-y-1 pl-5 text-sm">
          <li :for={rule <- NightFeeds.rules()}>{rule}</li>
        </ul>
        <h3 class="mt-3 text-sm font-semibold">Weaning one feed at a time</h3>
        <p class="mt-1 text-sm">
          Pick the feed that leaves you the longest unbroken sleep, not the earliest. Take a minute off
          a nursing session or 2 oz (60 ml) off a bottle each night, and move that food to the day.
          Once it's down to a minute or two, a feed that's still demanded can be answered by the
          non-nursing parent with soothing and no food. Then the next feed.
        </p>
        <h3 class="mt-3 text-sm font-semibold">When a dream feed helps</h3>
        <ul class="mt-1 list-disc space-y-1 pl-5 text-sm">
          <li :for={use <- NightFeeds.dream_feed_uses()}>{use}</li>
        </ul>
      </details>
    </section>
    """
  end

  attr :ok, :boolean, required: true

  defp gate_icon(assigns) do
    ~H"""
    <.icon
      name={if @ok, do: "hero-check-circle", else: "hero-minus-circle"}
      class={"mt-0.5 size-5 shrink-0 " <> if(@ok, do: "text-success", else: "opacity-70")}
    />
    """
  end

  defp age_text({:ok, _}), do: "They're past 13 weeks."

  defp age_text({:locked, nil}), do: "Night weaning isn't for the first 13 weeks."

  defp age_text({:locked, on}),
    do: "Night weaning waits until 13 weeks, from #{Calendar.strftime(on, "%b %-d")}."

  defp clearance_confirm(nil),
    do: "Record that your pediatrician is fine with cutting night feeds?"

  defp clearance_confirm(_), do: nil

  attr :plan, :map, required: true
  attr :unit_system, :atom, required: true
  attr :tz, :string, required: true

  defp night_feed_plan(assigns) do
    ~H"""
    <div id="night-feed-plan" class="mt-4 space-y-3 border-t border-base-300 pt-3 text-sm">
      <p :if={@plan.baseline_seconds} id="night-baseline">
        Best baseline between feeds:
        <span class="font-semibold">{format_duration(@plan.baseline_seconds)}</span>
      </p>
      <p :if={is_nil(@plan.baseline_seconds)} id="night-baseline-none" class="opacity-80">
        Not enough nights yet to find a baseline.
      </p>

      <p :if={@plan.earliest} id="night-earliest">
        <%= if @plan.earliest.state == :open do %>
          A feed is fine now: it's been long enough since the last one.
        <% else %>
          Hold off a feed until
          <span class="font-semibold tabular-nums">{clock(@plan.earliest.at, @tz)}</span>
          ({format_duration(@plan.earliest.seconds_left)} from now). Use the S.I.T. B.A.C.K. steps until then.
        <% end %>
      </p>

      <div :if={@plan.action in [:reduce, :hold]} id="night-tonight">
        <p class="font-medium">
          {if @plan.action == :reduce,
            do: "Tonight, a little less each night feed:",
            else: "Last night's amounts came down, so hold the same tonight:"}
        </p>
        <ul class="mt-1 space-y-0.5">
          <li :for={event <- @plan.tonight} class="tabular-nums">
            {clock(event.at, @tz)}: {feed_amount(event, @unit_system)}
          </li>
        </ul>
        <p class="mt-1 text-xs opacity-70">
          Take about half an ounce (15 ml) or 2 minutes off every other night. The dream feed isn't part
          of this. Offer extra in the daytime bottles.
        </p>
      </div>

      <p id="night-dream-feed" class="text-xs opacity-70">
        Dream feed: 2.5–3 hours after the bedtime feed and no later than {BedtimePlan.clock(
          elem(NightFeeds.dream_feed_window(), 1)
        )}. Keep it dark, swaddled and brief.
      </p>

      <p :if={@plan.goal_met?} id="night-goal-met" class="font-medium text-success">
        One night feed or fewer lately. That's the goal.
      </p>
    </div>
    """
  end

  defp feed_amount(%{suggested_ml: ml, ml: was}, system) do
    "#{Units.format(was, :volume, system)} → #{Units.format(ml, :volume, system)}"
  end

  defp feed_amount(%{suggested_minutes: min, minutes: was}, _system),
    do: "#{was} min → #{min} min"

  defp feed_amount(%{ml: ml}, system) when is_number(ml), do: Units.format(ml, :volume, system)
  defp feed_amount(%{minutes: min}, _system) when is_integer(min), do: "#{min} min"
  defp feed_amount(_event, _system), do: "feed"

  ## Night wakes ------------------------------------------------------------------

  attr :summary, :map, required: true
  attr :child_id, :integer, required: true

  def night_wakes_panel(assigns) do
    ~H"""
    <section id="toolkit-night-wakes" class={panel_class()}>
      <h2 class={heading_class()}>Night wakings</h2>

      <%= if @summary.count == 0 do %>
        <p id="night-wakes-empty" class="text-sm opacity-80">
          Work through a waking in night mode and how it went shows here.
        </p>
      <% else %>
        <p id="night-wakes-summary" class="text-sm">
          {@summary.count} in the last 2 weeks: {@summary.settled} settled, {@summary.fed} ended in a feed.
        </p>
        <p
          :if={@summary.settled_at != %{}}
          id="night-wakes-steps"
          class="mt-1 text-sm opacity-80"
        >
          Settled at step {settled_steps(@summary.settled_at)}.
        </p>
      <% end %>

      <.button
        id="open-night-mode"
        navigate={"/c/#{@child_id}/sleep/night"}
        size="sm"
        class="mt-3"
      >
        <.icon name="hero-moon" class="size-4" /> Night mode
      </.button>
    </section>
    """
  end

  defp settled_steps(settled_at) do
    settled_at
    |> Enum.sort()
    |> Enum.map_join(", ", fn {step, n} -> "#{step + 1} (#{n}×)" end)
  end

  ## Power tools -------------------------------------------------------------------

  attr :tools, :list, required: true
  attr :ticks, :map, default: %{}
  attr :age_days, :integer, default: nil
  attr :can_write, :boolean, required: true

  def power_tools_panel(assigns) do
    assigns =
      assign(assigns,
        signals:
          for {id, text} <- PowerTools.signals() do
            %{id: id, text: text, checked?: Map.has_key?(assigns.ticks || %{}, id)}
          end,
        lovey: PowerTools.lovey_note(assigns.age_days)
      )

    ~H"""
    <section id="toolkit-power-tools" class={panel_class()}>
      <h2 class={heading_class()}>Sleep tools</h2>
      <p class="text-xs opacity-70">
        The four things that make sleep easier without you doing it for them, and what to do with each one now.
      </p>

      <ul class="mt-3 space-y-3">
        <li
          :for={tool <- @tools}
          id={"tool-#{tool.id}"}
          data-state={tool.state}
          class="rounded-box border border-base-300 px-3 pb-3"
        >
          <div class="flex items-center justify-between gap-2">
            <h3 class="text-sm font-semibold">{tool.name}</h3>
            <span class={["badge badge-sm", tool_badge(tool.state)]}>{tool_state(tool.state)}</span>
          </div>
          <p :if={tool.state in [:stop, :consider]} class="mt-1 text-sm font-medium">
            {tool.headline}
          </p>
          <details class="fold mt-1">
            <summary class="cursor-pointer text-xs text-primary">
              {if tool.state in [:stop, :consider], do: "How", else: "What to do"}
            </summary>
            <p :if={tool.state not in [:stop, :consider]} class="mt-1 text-sm">{tool.headline}</p>
            <ul class="mt-1 list-disc space-y-1 pl-5 text-xs opacity-80">
              <li :for={point <- tool.points}>{point}</li>
            </ul>
          </details>
        </li>
      </ul>

      <h3 class="mt-4 text-sm font-semibold">Tell us if</h3>
      <ul id="tool-signals" class="mt-2 space-y-1.5">
        <.check_item
          :for={signal <- @signals}
          item={
            %{id: signal.id, text: signal.text, checked?: signal.checked?, auto?: false, detail: nil}
          }
          can_write={@can_write}
        />
      </ul>

      <p id="lovey-note" class="mt-3 text-xs opacity-70">{@lovey}</p>
    </section>
    """
  end

  defp tool_state(:use), do: "Use"
  defp tool_state(:consider), do: "Think about stopping"
  defp tool_state(:stop), do: "Stop"
  defp tool_state(:optional), do: "Optional"

  defp tool_badge(:use), do: "badge-success"
  defp tool_badge(:consider), do: "badge-warning"
  defp tool_badge(:stop), do: "badge-error"
  defp tool_badge(:optional), do: "badge-ghost"

  ## Safe sleep ---------------------------------------------------------------------

  attr :safe_sleep, :map, required: true
  attr :can_write, :boolean, required: true

  def safe_sleep_panel(assigns) do
    assigns = assign(assigns, :cosleeping, SafeSleep.cosleeping_notes())

    ~H"""
    <section id="toolkit-safe-sleep" class={panel_class()}>
      <h2 class={heading_class()}>
        Safe sleep
        <span id="safe-sleep-count" class="font-normal opacity-70">
          {@safe_sleep.done} of {@safe_sleep.total}
        </span>
      </h2>
      <div
        class="mb-2 h-2 overflow-hidden rounded-full bg-base-300"
        role="progressbar"
        aria-valuemin="0"
        aria-valuemax={@safe_sleep.total}
        aria-valuenow={@safe_sleep.done}
      >
        <div
          class="h-full rounded-full bg-success"
          style={"width: #{round(@safe_sleep.done / max(@safe_sleep.total, 1) * 100)}%"}
        >
        </div>
      </div>
      <details class="fold" id="safe-sleep-list">
        <summary class="cursor-pointer text-sm font-semibold text-primary">
          Run through the list
        </summary>
        <p class="mt-1 text-xs opacity-70">
          What lowers the risk of SIDS and accidents. Show it to your pediatrician, and give it to
          anyone who looks after them.
        </p>
        <ul id="safe-sleep-checklist" class="mt-2 space-y-1.5">
          <.check_item :for={item <- @safe_sleep.items} item={item} can_write={@can_write} />
        </ul>
      </details>

      <details id="cosleeping" class="fold mt-3">
        <summary class="cursor-pointer text-sm font-semibold text-primary">
          If you share a bed
        </summary>
        <p class="mt-1 text-xs opacity-70">
          The pediatricians' advice is not to. If it happens anyway, make it as safe as it can be.
        </p>
        <ul class="mt-2 list-disc space-y-1 pl-5 text-sm">
          <li :for={note <- @cosleeping}>{note}</li>
        </ul>
      </details>
    </section>
    """
  end

  ## Checklists --------------------------------------------------------------------

  attr :checklists, :map, required: true
  attr :can_write, :boolean, required: true

  def checklists_panel(assigns) do
    ~H"""
    <section id="toolkit-checklists" class={panel_class()}>
      <h2 class={heading_class()}>Checklists</h2>

      <details class="fold" id="success">
        <summary class="cursor-pointer text-sm font-semibold">
          Success checklist
          <span id="success-count" class="font-normal opacity-70">
            {@checklists.success_done} of {@checklists.success_total}
          </span>
        </summary>
        <ul id="success-checklist" class="mt-2 space-y-1.5">
          <.check_item :for={item <- @checklists.success} item={item} can_write={@can_write} />
        </ul>
      </details>

      <details id="troubleshooting" class="fold mt-3">
        <summary class="cursor-pointer text-sm font-semibold">
          Troubleshooting: when nights are hard
        </summary>
        <p class="mt-1 text-xs opacity-70">Tick each one you've checked.</p>
        <ul id="troubleshooting-checklist" class="mt-2 space-y-1.5">
          <.check_item :for={item <- @checklists.troubleshooting} item={item} can_write={@can_write} />
        </ul>
      </details>
    </section>
    """
  end

  attr :item, :map, required: true
  attr :can_write, :boolean, required: true

  defp check_item(assigns) do
    ~H"""
    <li id={"check-#{@item.id}"} data-checked={to_string(@item.checked?)} class="flex gap-2 text-sm">
      <%= if @item.auto? or not @can_write do %>
        <.icon
          name={if @item.checked?, do: "hero-check-circle-solid", else: "hero-minus-circle"}
          class={"mt-0.5 size-5 shrink-0 " <> if(@item.checked?, do: "text-success", else: "opacity-70")}
        />
      <% else %>
        <button
          type="button"
          phx-click="toggle_check"
          phx-value-id={@item.id}
          role="checkbox"
          aria-checked={to_string(@item.checked?)}
          aria-label={@item.text}
          class="-m-3 shrink-0 touch-manipulation p-3"
        >
          <.icon
            name={if @item.checked?, do: "hero-check-circle-solid", else: "hero-stop"}
            class={"size-5 " <> if(@item.checked?, do: "text-success", else: "opacity-70")}
          />
        </button>
      <% end %>
      <span class="min-w-0">
        {@item.text}
        <span :if={@item.detail} class="block text-xs opacity-70">
          {if @item.auto?, do: "Checked from the log: "}{@item.detail}
        </span>
      </span>
    </li>
    """
  end

  defp panel_class,
    do: "mb-4 rounded-[var(--radius-card)] border-2 border-base-300 bg-base-200/40 p-4"

  defp heading_class, do: "mb-2 text-sm font-semibold uppercase tracking-wide opacity-70"
end
