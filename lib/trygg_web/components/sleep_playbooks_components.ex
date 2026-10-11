defmodule TryggWeb.SleepPlaybooksComponents do
  @moduledoc """
  The panels of the Sleep playbooks page: what the log says is worth a look, the
  nap conventions, three planners (bedtime shift, clock change, travel) and the
  playbook cards, from `Trygg.Sleep.Setbacks` and `Trygg.Sleep.NapConventions`.
  Fed by `Trygg.Reports.sleep_playbooks/3`.
  """
  use Phoenix.Component

  import TryggWeb.CoreComponents

  import TryggWeb.SleepPlanComponents, only: [what_to_try: 1]

  alias Phoenix.LiveView.JS
  alias Trygg.Sleep.{BedtimePlan, NapConventions, Setbacks}

  ## What's worth a look ---------------------------------------------------------

  attr :findings, :list, required: true

  def findings_panel(assigns) do
    ~H"""
    <section id="findings" class={panel_class()}>
      <h2 class={heading_class()}>Worth a look</h2>
      <p :if={@findings == []} id="findings-none" class="text-sm opacity-80">
        Nothing stands out in the last two weeks.
      </p>
      <ul :if={@findings != []} class="space-y-3">
        <li :for={finding <- @findings} id={"finding-#{finding.id}"} class="text-sm">
          <p class="font-semibold">{finding.title}</p>
          <p class="opacity-80">{finding.detail}</p>
          <a
            :if={finding.playbook}
            href={"#playbook-#{finding.playbook}"}
            phx-click={JS.set_attribute({"open", ""}, to: "#playbook-#{finding.playbook}")}
            class="inline-flex min-h-11 items-center text-sm text-primary underline"
          >
            See the playbook below
          </a>
          <.what_to_try
            :if={is_nil(finding.playbook)}
            points={finding.points}
            id={"try-#{finding.id}"}
          />
        </li>
      </ul>
    </section>
    """
  end

  ## Naps -------------------------------------------------------------------------

  attr :naps, :map, required: true
  attr :drop, :map, default: nil

  def naps_panel(assigns) do
    assigns =
      assign(assigns,
        conventions: NapConventions.conventions(),
        fixes: NapConventions.short_nap_fixes(),
        signs: NapConventions.drop_signs(),
        tips: NapConventions.transition_tips()
      )

    ~H"""
    <section id="naps" class={panel_class()}>
      <h2 class={heading_class()}>Naps</h2>

      <div id="nap-checks" class="space-y-1 text-sm">
        <p :if={@naps.place} id="nap-place">
          <.icon
            name={if @naps.place.ok?, do: "hero-check-circle", else: "hero-minus-circle"}
            class={"mr-1 size-4 align-text-bottom " <> if(@naps.place.ok?, do: "text-success", else: "opacity-70")}
          />
          {round(@naps.place.share * 100)}% of the last {@naps.place.count} naps were in the same place ({@naps.place.where}).
          The aim is about 80%.
        </p>
        <p :if={is_nil(@naps.place)} id="nap-place-none" class="opacity-70">
          Note where they nap (crib, bassinet, on you, stroller) and this shows how consistent it is.
        </p>
        <p id="nap-catnaps">
          <.icon
            name={if @naps.catnaps.ok?, do: "hero-check-circle", else: "hero-minus-circle"}
            class={"mr-1 size-4 align-text-bottom " <> if(@naps.catnaps.ok?, do: "text-success", else: "opacity-70")}
          />
          {catnap_text(@naps.catnaps)}
        </p>
      </div>

      <p :if={@drop} id="nap-drop-now" class="mt-3 text-sm">
        <span class="font-medium">At {@drop.label}:</span> {@drop.text}
      </p>

      <div class="mt-3 space-y-2">
        <details id="nap-conventions-wrap" class="fold rounded-box border border-base-300 px-3 pb-3">
          <summary class="cursor-pointer text-sm font-semibold">The four jobs</summary>
          <p class="mt-2 text-sm">
            You can't make them nap, but you can soothe, be consistent, get the timing right and, from
            3–6 months, let them learn to fall asleep alone.
          </p>
          <ol id="nap-conventions" class="mt-2 space-y-2">
            <li :for={{convention, i} <- Enum.with_index(@conventions, 1)} class="text-sm">
              <span class="font-semibold">{i}. {convention.name}.</span>
              <span class="opacity-80">{convention.detail}</span>
            </li>
          </ol>
        </details>

        <details id="short-naps" class="fold rounded-box border border-base-300 px-3 pb-3">
          <summary class="cursor-pointer text-sm font-semibold">Short naps</summary>
          <ul id="short-nap-fixes" class="mt-2 space-y-1.5 text-sm">
            <li :for={fix <- @fixes}>
              <span class="font-semibold">{fix.name}.</span>
              <span class="opacity-80">{fix.detail}</span>
            </li>
          </ul>
        </details>

        <details id="nap-drop-signs" class="fold rounded-box border border-base-300 px-3 pb-3">
          <summary class="cursor-pointer text-sm font-semibold">Dropping a nap</summary>
          <p class="mt-2 text-sm font-medium">Signs a nap is on its way out</p>
          <ul class="mt-1 list-disc space-y-1 pl-5 text-sm">
            <li :for={sign <- @signs}>{sign}</li>
          </ul>
          <p class="mt-2 text-sm font-medium">While you get through it</p>
          <ul class="mt-1 list-disc space-y-1 pl-5 text-sm">
            <li :for={tip <- @tips}>{tip}</li>
          </ul>
        </details>
      </div>
    </section>
    """
  end

  defp catnap_text(%{days: 0}),
    do: "They've had enough time awake before bed lately. Good: it keeps bedtime defended."

  defp catnap_text(%{days: n}),
    do:
      "On #{n} of the last 7 evenings they were awake less than the guide's minimum before bed. Late catnaps work against bedtime."

  ## Planners ----------------------------------------------------------------------

  attr :form, :map, required: true
  attr :rows, :list, required: true
  attr :open, :boolean, default: false

  def shift_planner(assigns) do
    ~H"""
    <details id="shift-planner" class={["fold", panel_class()]} open={@open}>
      <summary class={[heading_class(), "cursor-pointer"]}>Move bedtime</summary>
      <p class="text-sm">
        15 minutes a day, a little at a time. Leave the wake time alone if they're getting enough sleep;
        if bedtime is very late, wake them 15 minutes earlier each morning and shift naps with it, and keep lights
        low from the new bedtime onward, with bright light first thing.
      </p>
      <.form for={@form} id="shift-form" phx-change="shift_change" class="mt-3">
        <div class="grid grid-cols-2 gap-3">
          <.input field={@form[:from_bed]} type="time" label="Bedtime now" />
          <.input field={@form[:to_bed]} type="time" label="Bedtime I want" />
          <.input field={@form[:from_wake]} type="time" label="Wake time now" />
          <.input field={@form[:to_wake]} type="time" label="Wake time I want" />
        </div>
      </.form>
      <p :if={@rows == []} id="shift-none" class="mt-2 text-sm opacity-70">
        Fill in the bedtimes to see the days.
      </p>
      <table :if={@rows != []} id="shift-table" class="mt-3 w-full text-sm">
        <thead>
          <tr class="text-left text-xs opacity-70">
            <th class="py-1">Day</th>
            <th>Bedtime</th>
            <th>Wake</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows} id={"shift-day-#{row.day}"} class="border-t border-base-300">
            <td class="py-1">{row.day}</td>
            <td class="tabular-nums">{BedtimePlan.clock(row.bed)}</td>
            <td class="tabular-nums">{row.wake && BedtimePlan.clock(row.wake)}</td>
          </tr>
        </tbody>
      </table>
    </details>
    """
  end

  attr :form, :map, required: true
  attr :plan, :map, required: true
  attr :open, :boolean, default: false

  def dst_planner(assigns) do
    ~H"""
    <details id="dst-planner" class={["fold", panel_class()]} open={@open}>
      <summary class={[heading_class(), "cursor-pointer"]}>Clock change</summary>
      <.form for={@form} id="dst-form" phx-change="dst_change" class="mt-2">
        <div class="grid grid-cols-2 gap-3">
          <.input
            field={@form[:direction]}
            type="select"
            label="Clocks go"
            options={[{"Forward (spring)", "forward"}, {"Back (autumn)", "back"}]}
          />
          <.input field={@form[:date]} type="date" label="On" />
          <.input field={@form[:bed]} type="time" label="Usual bedtime" />
          <.input field={@form[:wake]} type="time" label="Usual wake time" />
        </div>
      </.form>

      <table :if={@plan.rows != []} id="dst-table" class="mt-3 w-full text-sm">
        <thead>
          <tr class="text-left text-xs opacity-70">
            <th class="py-1">Evening</th>
            <th>Bedtime</th>
            <th>Wake next morning</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={{row, i} <- Enum.with_index(@plan.rows, 1)}
            id={"dst-day-#{i}"}
            class="border-t border-base-300"
          >
            <td class="py-1">{Calendar.strftime(row.date, "%a %b %-d")}</td>
            <td class="tabular-nums">{BedtimePlan.clock(row.bed)}</td>
            <td class="tabular-nums">
              {BedtimePlan.clock(row.wake)}{if row.new_clock?, do: " (new clock)"}
            </td>
          </tr>
        </tbody>
      </table>
      <ul id="dst-tips" class="mt-3 list-disc space-y-1 pl-5 text-sm">
        <li :for={tip <- @plan.tips}>{tip}</li>
      </ul>
    </details>
    """
  end

  attr :form, :map, required: true
  attr :plan, :map, required: true
  attr :open, :boolean, default: false

  def travel_planner(assigns) do
    ~H"""
    <details id="travel-planner" class={["fold", panel_class()]} open={@open}>
      <summary class={[heading_class(), "cursor-pointer"]}>Travel</summary>
      <.form for={@form} id="travel-form" phx-change="travel_change" class="mt-2">
        <div class="grid grid-cols-3 gap-3">
          <.input field={@form[:hours]} type="number" min="0" max="12" label="Time zones" />
          <.input
            field={@form[:direction]}
            type="select"
            label="Going"
            options={[{"West", "west"}, {"East", "east"}]}
          />
          <.input field={@form[:days]} type="number" min="1" max="60" label="Days away" />
        </div>
      </.form>

      <p :if={@plan.keep_home_time?} id="travel-keep-home" class="mt-3 text-sm font-medium">
        Stay on home time. It's short enough not to adjust twice.
      </p>
      <p :if={not @plan.keep_home_time?} id="travel-adjust" class="mt-3 text-sm">
        Count on about <span class="font-semibold">{@plan.adjust_days} days</span>
        to adjust, a day an hour.
        <span :if={@plan.light}>
          Bright light, outside if you can, between
          <span class="font-semibold tabular-nums">
            {BedtimePlan.clock(elem(@plan.light, 0))}–{BedtimePlan.clock(elem(@plan.light, 1))}
          </span>
          on the clock back home. Do the same in reverse on the way back.
        </span>
      </p>
      <ul id="travel-tips" class="mt-3 list-disc space-y-1 pl-5 text-sm">
        <li :for={tip <- @plan.tips}>{tip}</li>
      </ul>
    </details>
    """
  end

  ## Playbooks ----------------------------------------------------------------------

  def playbook_cards(assigns) do
    assigns = assign(assigns, :playbooks, Setbacks.playbooks())

    ~H"""
    <section id="playbooks" class={panel_class()}>
      <h2 class={heading_class()}>Playbooks</h2>
      <div class="space-y-2">
        <details
          :for={book <- @playbooks}
          id={"playbook-#{book.id}"}
          class="fold rounded-box border border-base-300 px-3 pb-3"
        >
          <summary class="cursor-pointer text-sm font-semibold">{book.title}</summary>
          <p class="mt-2 text-sm">{book.summary}</p>
          <ul class="mt-2 list-disc space-y-1 pl-5 text-sm opacity-90">
            <li :for={point <- book.points}>{point}</li>
          </ul>
        </details>
      </div>
    </section>
    """
  end

  def medical_panel(assigns) do
    assigns = assign(assigns, :items, Setbacks.medical())

    ~H"""
    <section id="medical" class={panel_class()}>
      <h2 class={heading_class()}>When to ask the pediatrician</h2>
      <p class="text-sm">
        Most of the time they're not sleeping because they're a baby. These are the exceptions worth a
        conversation. Not medical advice.
      </p>
      <div class="mt-3 space-y-2">
        <details
          :for={item <- @items}
          id={"medical-#{item.id}"}
          class="fold rounded-box border border-base-300 px-3 pb-3"
        >
          <summary class="cursor-pointer text-sm font-semibold">{item.title}</summary>
          <ul class="mt-2 list-disc space-y-1 pl-5 text-sm opacity-90">
            <li :for={point <- item.points}>{point}</li>
          </ul>
        </details>
      </div>
    </section>
    """
  end

  defp panel_class,
    do: "mb-4 rounded-[var(--radius-card)] border-2 border-base-300 bg-base-200/40 p-4"

  defp heading_class, do: "mb-2 text-sm font-semibold uppercase tracking-wide opacity-70"
end
