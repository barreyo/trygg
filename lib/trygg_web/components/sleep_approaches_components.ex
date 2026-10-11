defmodule TryggWeb.SleepApproachesComponents do
  @moduledoc """
  The Sleep plan page's choice of approach and the panels for the two plans
  that come from *Precious Little Sleep*: the gradual Sleep With Assistance
  Plans (`Trygg.Sleep.Swap`) and the Sleep Learning Independence Plan
  (`Trygg.Sleep.Slip`), next to "The ABCs of Sleep" (`TryggWeb.SleepAbcsComponents`).

  Fed by `Trygg.Reports.sleep_training/3`.
  """
  use Phoenix.Component

  import TryggWeb.CoreComponents
  alias Trygg.Sleep.{NapConventions, NightFeeds, Slip, Swap}

  ## Choosing ---------------------------------------------------------------------

  attr :recommendation, :map, required: true
  attr :eligibilities, :map, required: true
  attr :choice, :atom, default: nil
  attr :child_id, :integer, required: true

  def approach_picker(assigns) do
    assigns =
      assign(assigns,
        cards: [
          %{
            id: :swap,
            title: "Gradual",
            tag: "Sleep With Assistance Plan",
            text:
              "Do a little less each night to help them fall asleep. Seven ways to do it, for suckers, cuddlers and motion lovers. From 2 months."
          },
          %{
            id: :slip,
            title: "Sleep learning (SLIP)",
            tag: "Sleep Learning Independence Plan",
            text:
              "Put them down awake and let them learn, with brief visits that grow, or none. A few hard nights, then easier. From 4 months."
          },
          %{
            id: :abcs,
            title: "The ABCs of Sleep",
            tag: "14 nights",
            text:
              "Pop-ins at 5, 10 and then every 15 minutes, a night-weaning table, and a nap plan after. From 5 months."
          }
        ]
      )

    ~H"""
    <section id="approach-picker" class={panel_class()}>
      <h2 class={heading_class()}>Teaching independent sleep</h2>

      <p :if={@recommendation.suggested == :tools} id="approach-too-young" class="text-sm">
        They're too young for a plan: for now it's soothing, not teaching.
        <.link navigate={"/c/#{@child_id}/sleep/toolkit"} class="text-primary underline">
          The sleep tools
        </.link>
        and the newborn guidance are the place to start.
      </p>

      <div class="grid gap-2">
        <.button
          :for={card <- @cards}
          id={"approach-#{card.id}"}
          type="button"
          variant={if @choice == card.id, do: "primary"}
          phx-click="choose"
          phx-value-approach={card.id}
          aria-pressed={to_string(@choice == card.id)}
          data-suggested={to_string(@recommendation.suggested == card.id)}
          class="h-auto min-h-11 w-full flex-col items-stretch gap-0.5 py-3 text-left font-normal normal-case"
        >
          <span class="flex items-center justify-between gap-2">
            <span class="text-base font-semibold tracking-tight">{card.title}</span>
            <span :if={@recommendation.suggested == card.id} class="badge badge-sm badge-neutral">
              Suggested
            </span>
            <span
              :if={match?({:locked, _}, @eligibilities[card.id].age)}
              class="badge badge-sm badge-ghost"
            >
              Locked
            </span>
          </span>
          <span class="block text-xs font-normal opacity-80">{card.tag}</span>
          <span class="block text-sm font-normal">{card.text}</span>
        </.button>
      </div>

      <p :if={@recommendation.suggested != :tools} id="approach-why" class="mt-3 text-sm">
        {@recommendation.why}
      </p>

      <details :if={@recommendation.suggested != :tools} id="approach-reasons" class="fold mt-2">
        <summary class="cursor-pointer text-sm text-primary">How to choose</summary>
        <ul class="mt-2 list-disc space-y-1 pl-5 text-sm opacity-90">
          <li :for={reason <- @recommendation.reasons}>{reason}</li>
        </ul>
        <p class="mt-2 text-xs opacity-70">
          Pick one, commit to it, and judge it by the trend, not one night. Not medical advice. Talk
          to your pediatrician first.
        </p>
      </details>
    </section>
    """
  end

  ## SWAP -------------------------------------------------------------------------

  def swap_intro(assigns) do
    ~H"""
    <section id="swap-intro" class={panel_class()}>
      <h2 class={heading_class()}>A gradual plan</h2>
      <p class="text-sm leading-snug">
        You change how they fall asleep a little at a time, and you stay with it. It takes longer than
        sleep learning (often a week or two) and asks you to stay consistent the whole time. Most babies
        protest any change, and a few tears are normal.
      </p>
      <ul class="mt-3 list-disc space-y-1 pl-5 text-sm leading-snug">
        <li>Start with bedtime: the pull to sleep is strongest then.</li>
        <li>The same bedtime and routine every night, in a dark room with sound on.</li>
        <li>Pick one plan and stick with it for 5–7 nights. Don't slip back "just this once".</li>
        <li>
          Night wakings: either go in within 5–10 minutes or wait until they're asleep. Do a little less
          each night.
        </li>
        <li>
          Once they fall asleep without help, you should see at least half the wakings go. Feeds are a
          separate job.
        </li>
      </ul>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :variant, :map, required: true
  attr :suggested, :atom, required: true
  attr :ready?, :boolean, required: true

  def swap_setup_form(assigns) do
    assigns =
      assign(assigns,
        options: for(v <- Swap.variants(), do: {"#{v.name}: #{v.who}", Atom.to_string(v.id)}),
        minutes?: assigns.variant.id in [:jiggle, :pat]
      )

    ~H"""
    <section id="swap-setup" class={panel_class()}>
      <h2 class={heading_class()}>Pick a way</h2>

      <.form
        for={@form}
        id="swap-setup-form"
        phx-change="swap_change"
        phx-submit="start_plan"
        class="space-y-3"
      >
        <input type="hidden" name="plan[definition]" value="swap" />
        <.input
          field={@form[:variant]}
          id="swap-variant"
          type="select"
          label="Plan"
          options={@options}
        />
        <p :if={@variant.id == @suggested} class="text-xs text-primary">
          Suggested from how they fall asleep now.
        </p>

        <p id="swap-summary" class="text-sm">{@variant.summary}</p>
        <ol id="swap-steps" class="list-decimal space-y-1 pl-5 text-sm opacity-90">
          <li :for={step <- @variant.steps}>{step}</li>
        </ol>
        <p class="text-xs opacity-70">It runs {@variant.nights} nights, then you review it.</p>

        <.input
          :if={@minutes?}
          field={@form[:start_minutes]}
          id="swap-start-minutes"
          type="number"
          min="1"
          max="120"
          label="How long does it take now (minutes)?"
        />

        <.button
          id="start-swap"
          variant="primary"
          class="w-full"
          disabled={!@ready?}
          data-confirm="Start night 1 tonight? Plan on sticking to it for at least five nights."
        >
          Start night 1 tonight
        </.button>
        <p :if={!@ready?} id="start-plan-blocked" class="text-xs opacity-70">
          Finish the list first.
        </p>
      </.form>
    </section>
    """
  end

  attr :tonight, :map, required: true
  attr :plan, :map, required: true
  attr :child_id, :integer, required: true
  attr :can_write, :boolean, required: true

  def swap_tonight_panel(assigns) do
    ~H"""
    <section id="swap-tonight" class={panel_class()}>
      <.tonight_heading tonight={@tonight} />

      <%= if @tonight.finished? do %>
        <p id="swap-finished" class="mt-3 text-sm leading-snug">
          That's the {@tonight.nights} nights. Look at the trend below. If bedtime is quicker, keep doing
          what you're doing and move on to naps. If it isn't, it may not be the right plan: try another,
          or the sleep learning plan.
        </p>
      <% else %>
        <ul class="mt-3 space-y-2 text-sm leading-snug">
          <li id="swap-name">
            <span class="font-semibold">{@tonight.variant.name}.</span> {@tonight.variant.who}.
          </li>
          <li id="swap-step">
            <span class="font-semibold">Tonight:</span> {@tonight.step.headline}
          </li>
          <li id="swap-bedtime">
            <span class="font-semibold">Bedtime</span>
            at the usual time, the same routine, then start. Put them down awake if you can.
          </li>
          <li id="swap-night-wakings">
            <span class="font-semibold">Night wakings:</span>
            go in within 5–10 minutes or wait until they're asleep, and do the same thing you did at bedtime, a little less than last night.
          </li>
        </ul>
        <.open_night_mode can_write={@can_write} child_id={@child_id} />
      <% end %>
    </section>
    """
  end

  def swap_checks(assigns) do
    assigns =
      assign(assigns,
        progress: Swap.signs_of_progress(),
        stalls: Swap.reasons_it_stalls(),
        waking: Swap.still_waking()
      )

    ~H"""
    <section id="swap-checks" class={panel_class()}>
      <h2 class={heading_class()}>Is it working?</h2>
      <p class="text-sm font-medium">Signs you're on track</p>
      <ul class="mt-1 list-disc space-y-1 pl-5 text-sm">
        <li :for={sign <- @progress}>{sign}</li>
      </ul>
      <details id="swap-stalls" class="fold mt-3">
        <summary class="cursor-pointer text-sm font-semibold text-primary">
          If it isn't after a week
        </summary>
        <ul class="mt-2 list-disc space-y-1 pl-5 text-sm">
          <li :for={reason <- @stalls}>{reason}</li>
        </ul>
      </details>
      <details id="swap-still-waking" class="fold mt-3">
        <summary class="cursor-pointer text-sm font-semibold text-primary">
          Bedtime is fine but nights are still broken
        </summary>
        <ul class="mt-2 list-disc space-y-1 pl-5 text-sm">
          <li :for={reason <- @waking}>{reason}</li>
        </ul>
      </details>
    </section>
    """
  end

  ## SLIP -------------------------------------------------------------------------

  def slip_intro(assigns) do
    assigns = assign(assigns, points: Slip.summary())

    ~H"""
    <section id="slip-intro" class={panel_class()}>
      <h2 class={heading_class()}>The Sleep Learning Independence Plan</h2>
      <p class="text-sm leading-snug">
        For when a gradual approach hasn't worked or you've nothing left to give. They learn to fall
        asleep on their own. It involves tears, and typically works within three nights. It isn't for
        every baby or every family, and it's fine to wait.
      </p>
      <ul class="mt-3 list-disc space-y-1 pl-5 text-sm leading-snug">
        <li :for={point <- @points}>{point}</li>
      </ul>
      <p class="mt-3 text-sm leading-snug opacity-80">
        What to expect at bedtime, roughly: night 1, 45–90 minutes; night 2, 20–45; night 3, up to 25.
        The trend matters more than any one night. Some babies cry harder for a night or two once it
        stops working (an <em>extinction burst</em>): that passes, and it's why the plan only works if
        you don't give in.
      </p>
      <p class="mt-3 text-xs opacity-70">
        Not medical advice. Don't start with a fever or illness, and check with your pediatrician first.
      </p>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :ready?, :boolean, required: true

  def slip_setup_form(assigns) do
    assigns = assign(assigns, table: for(night <- 1..5, do: {night, Slip.schedule(night, 4)}))

    ~H"""
    <section id="slip-setup" class={panel_class()}>
      <h2 class={heading_class()}>Visits or no visits</h2>

      <.form
        for={@form}
        id="slip-setup-form"
        phx-change="slip_change"
        phx-submit="start_plan"
        class="space-y-3"
      >
        <input type="hidden" name="plan[definition]" value="slip" />
        <.input
          field={@form[:mode]}
          id="slip-mode"
          type="select"
          label="Check-ins"
          options={[
            {"Graduated: brief visits at growing intervals", "graduated"},
            {"Full: no visits until they're asleep", "full"}
          ]}
        />

        <p class="text-sm">
          Both work and neither is more loving. The book finds full works faster and with less crying,
          because a visit can wind them up. You can start with visits and stop them later, but not the
          other way: once you've decided not to go in, you stay out.
        </p>

        <div id="slip-table-wrap" class="overflow-x-auto">
          <table id="slip-table" class="w-full min-w-[20rem] text-left text-sm">
            <caption class="pb-1 text-left text-xs opacity-70">
              The 5-minute plan: minutes before each visit
            </caption>
            <thead class="text-xs uppercase opacity-70">
              <tr>
                <th class="pr-2">Night</th>
                <th class="pr-2">1st</th>
                <th class="pr-2">2nd</th>
                <th class="pr-2">3rd</th>
                <th>then</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={{night, [a, b, c, d]} <- @table}
                id={"slip-night-#{night}"}
                class="border-t border-base-300"
              >
                <th scope="row" class="py-1 pr-2">{night}</th>
                <td class="pr-2 tabular-nums">{div(a, 60)}</td>
                <td class="pr-2 tabular-nums">{div(b, 60)}</td>
                <td class="pr-2 tabular-nums">{div(c, 60)}</td>
                <td class="tabular-nums">{div(d, 60)}, +5 …</td>
              </tr>
            </tbody>
          </table>
        </div>
        <p class="text-xs opacity-70">
          A visit is a minute or two: your bedtime words, no picking up, and leave while they're still awake.
        </p>

        <.button
          id="start-slip"
          variant="primary"
          class="w-full"
          disabled={!@ready?}
          data-confirm="Start night 1 tonight? Both of you need to be ready not to go back to the old way."
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

  attr :tonight, :map, required: true
  attr :plan, :map, required: true
  attr :child_id, :integer, required: true
  attr :can_write, :boolean, required: true

  def slip_tonight_panel(assigns) do
    ~H"""
    <section id="slip-tonight" class={panel_class()}>
      <.tonight_heading tonight={@tonight} />

      <%= if @tonight.finished? do %>
        <p id="slip-finished" class="mt-3 text-sm leading-snug">
          That's the {@tonight.nights} nights. Keep doing the same: the routine, down awake, and no
          going back to rocking, feeding or the pacifier to sleep. Setbacks (illness, travel) happen:
          get back to the plan afterwards.
        </p>
      <% else %>
        <ul class="mt-3 space-y-2 text-sm leading-snug">
          <li id="slip-bedtime">
            <span class="font-semibold">Bedtime</span>
            at the usual time. The routine, without the last step of soothing them to sleep, then down
            awake in the crib with your goodnight words.
          </li>
          <li :if={@tonight.mode == :graduated} id="slip-visits">
            <span class="font-semibold">Visits tonight:</span>
            after {format_visits(@tonight.visits)} of crying (then 5 minutes longer each time). A minute
            or two each: your words, no picking up, and leave while they're awake.
          </li>
          <li :if={@tonight.mode == :full} id="slip-full">
            <span class="font-semibold">No visits.</span>
            You don't go in until they're asleep. Is the baby safe, fed and loved? Then they're learning.
          </li>
          <li id="slip-expect">
            <span class="font-semibold">Expect</span>
            roughly {@tonight.expected.label} of crying at bedtime tonight, but it varies.
          </li>
          <li id="slip-night-wakings">
            <span class="font-semibold">Night wakings:</span>
            handle them the way you handled bedtime. A brief 5–15 minute grumble is a baby cycling
            through light sleep, not an emergency. Feed if they were eating at night, by the plan.
          </li>
        </ul>
        <.open_night_mode can_write={@can_write} child_id={@child_id} />
      <% end %>
    </section>
    """
  end

  defp format_visits(visits) do
    visits
    |> Enum.take(3)
    |> Enum.map_join(", ", &"#{div(&1, 60)}")
    |> Kernel.<>(" minutes")
  end

  ## Shared -----------------------------------------------------------------------

  attr :tonight, :map, required: true

  defp tonight_heading(assigns) do
    ~H"""
    <h2 class={heading_class()}>
      <%= cond do %>
        <% @tonight.night == 0 -> %>
          Starts tonight
        <% @tonight.finished? -> %>
          All {@tonight.nights} nights done
        <% true -> %>
          Night {@tonight.night} of {@tonight.nights}
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
    """
  end

  attr :can_write, :boolean, required: true
  attr :child_id, :integer, required: true

  defp open_night_mode(assigns) do
    ~H"""
    <.button
      :if={@can_write}
      id="abcs-open-night-mode"
      navigate={"/c/#{@child_id}/sleep/night"}
      variant="primary"
      class="mt-4 w-full"
    >
      <.icon name="hero-moon" class="size-5" /> Open night mode
    </.button>
    """
  end

  @doc "Night feeds while a plan runs: the rules for which wakings get a feed."
  def feed_rules_panel(assigns) do
    assigns = assign(assigns, rules: NightFeeds.rules())

    ~H"""
    <section id="plan-feed-rules" class={panel_class()}>
      <h2 class={heading_class()}>Night feeds</h2>
      <p class="text-sm">
        Learning to fall asleep alone isn't night weaning. A baby who has been eating a lot at night
        will keep wanting to for a while. Feed by the rules, not by the loudest cry.
      </p>
      <details class="fold mt-2">
        <summary class="cursor-pointer text-sm text-primary">The rules</summary>
        <ul class="mt-2 list-disc space-y-1 pl-5 text-sm">
          <li :for={rule <- @rules}>{rule}</li>
        </ul>
      </details>
    </section>
    """
  end

  @doc "Naps after the nights: the book's \"Nap Master Plan\"."
  def nap_master_plan(assigns) do
    assigns =
      assign(assigns,
        conventions: NapConventions.conventions(),
        steps: NapConventions.master_plan()
      )

    ~H"""
    <section id="nap-master-plan" class={panel_class()}>
      <h2 class={heading_class()}>Then, naps</h2>
      <p class="text-sm">
        Independent sleep is learned twice: once at bedtime, and again for naps. Do bedtime first, then
        use the same plan for naps.
      </p>
      <details id="nap-master-steps" class="fold mt-2">
        <summary class="cursor-pointer text-sm text-primary">The three steps</summary>
        <ol class="mt-2 space-y-2 text-sm">
          <li :for={{step, i} <- Enum.with_index(@steps, 1)}>
            <span class="font-semibold">{i}. {step.name}.</span> {step.detail}
          </li>
        </ol>
        <p class="mt-2 text-xs opacity-70">
          Rocking, feeding or the pacifier at naps won't undo bedtime. A micro-nap is a win.
        </p>
      </details>
    </section>
    """
  end

  defp panel_class,
    do: "mb-4 rounded-[var(--radius-card)] border-2 border-base-300 bg-base-200/40 p-4"

  defp heading_class, do: "mb-2 text-sm font-semibold uppercase tracking-wide opacity-70"
end
