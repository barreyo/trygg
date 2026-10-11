defmodule TryggWeb.SleepPlanComponents do
  @moduledoc """
  Home's sleep coaching pieces: the sleepy-cue chips on the Sleep card, the
  Sleep plan card (phase, cue and feed-to-sleep habits, what's next) and the
  C.R.I.E.S. soothing sheet.

  Fed by `Trygg.Sleep.Phase` and `Trygg.Reports.SleepHabits`; the guidance they
  encode comes from the Taking Cara Babies guides (see `Trygg.Sleep.Cue` and
  `Trygg.Sleep.Cries`).
  """
  use Phoenix.Component

  import TryggWeb.CoreComponents
  import TryggWeb.LogComponents, only: [format_duration: 1]

  alias Phoenix.LiveView.JS
  alias Trygg.Reports.SleepHabits
  alias Trygg.Sleep.{Cries, Cue}

  @doc """
  Three tap-to-toggle chips for the sleepy cue (tired / ready / overtired).
  Each pushes `set_cue` with the cue id; `selected` is the one currently set.
  """
  attr :id, :string, default: "cue-chips"
  attr :selected, :string, default: nil
  attr :label, :string, required: true

  def cue_chips(assigns) do
    ~H"""
    <div id={@id} class="mt-2 space-y-1.5">
      <span class="block text-xs opacity-80">{@label}</span>
      <div class="grid grid-cols-3 gap-1.5">
        <.button
          :for={cue <- Cue.all()}
          id={"cue-chip-#{cue.id}"}
          type="button"
          size="xs"
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

  @doc """
  The Sleep plan card. `phase` is a `Trygg.Sleep.Phase.for_child/2` map and
  `habits` a `Trygg.Reports.SleepHabits.summarize/4` map.
  """
  attr :phase, :map, required: true
  attr :habits, :map, required: true

  def sleep_plan_card(assigns) do
    ~H"""
    <section
      id="sleep-plan"
      class="mt-3 space-y-3 rounded-[var(--radius-card)] border-2 border-base-300 bg-base-200/40 p-4"
    >
      <div class="flex items-start justify-between gap-3">
        <div>
          <p class="text-xs font-semibold uppercase tracking-wide opacity-70">Sleep plan</p>
          <h2 id="sleep-plan-phase" class="text-lg font-bold leading-tight">
            {@phase.label} · {week_label(@phase.week)}
          </h2>
        </div>
        <span class="text-2xl leading-none" aria-hidden="true">🌙</span>
      </div>

      <p id="sleep-plan-blurb" class="text-sm leading-snug opacity-80">{blurb(@phase.id)}</p>

      <ul class="space-y-2 text-sm leading-snug">
        <li :if={cues_line(@habits)} id="sleep-plan-cues">{cues_line(@habits)}</li>
        <li :if={windows_line(@habits)} id="sleep-plan-windows">{windows_line(@habits)}</li>
        <li :if={feed_sleep_line(@habits)} id="sleep-plan-feed-sleep">
          {feed_sleep_line(@habits)}
          <span class="block text-xs opacity-70">
            Just a pattern to see — feeding to sleep is normal at this age.
          </span>
        </li>
      </ul>

      <%!-- `open` is the reader's, not the server's: keep it across re-renders. --%>
      <details
        id="cue-guide"
        class="text-sm"
        phx-mounted={JS.ignore_attributes(["open"])}
      >
        <summary class="cursor-pointer font-medium text-primary">
          What do sleepy cues look like?
        </summary>
        <dl class="mt-2 space-y-1.5">
          <div :for={cue <- Cue.all()} id={"cue-guide-#{cue.id}"}>
            <dt class="font-medium">{cue.title}</dt>
            <dd class="opacity-80">{Enum.join(cue.signs, " · ")}</dd>
          </div>
        </dl>
      </details>

      <.button
        :if={@phase.id == :newborn}
        id="open-cries"
        type="button"
        variant="outline"
        class="w-full"
        phx-click="open_sheet"
        phx-value-kind="cries"
      >
        <.icon name="hero-heart" class="size-5" /> Soothing steps (C.R.I.E.S.)
      </.button>

      <p :if={@phase.next} id="sleep-plan-next" class="text-xs opacity-70">
        Next: {@phase.next.label} from {Calendar.strftime(@phase.next.on, "%b %-d")} ({time_to_go(
          @phase.next.in_days
        )}).
      </p>
    </section>
    """
  end

  @doc "Body of the C.R.I.E.S. soothing sheet."
  def cries_sheet(assigns) do
    assigns = assign(assigns, :steps, Cries.steps())

    ~H"""
    <h3 class="font-semibold text-lg mb-1">When they cry</h3>
    <p class="text-sm opacity-70 mb-4">
      C.R.I.E.S. — a calming order to try, from the Taking Cara Babies newborn guidance.
    </p>
    <ol id="cries-steps" class="space-y-3">
      <li :for={step <- @steps} id={"cries-#{String.downcase(step.letter)}"} class="flex gap-3">
        <span class="grid size-9 shrink-0 place-items-center rounded-full bg-primary text-lg font-bold text-primary-content">
          {step.letter}
        </span>
        <div class="min-w-0">
          <p class="font-semibold leading-tight">{step.name}</p>
          <p class="text-sm opacity-80 leading-snug">{step.detail}</p>
        </div>
      </li>
    </ol>
    <p class="mt-4 text-xs opacity-70">
      Hungry, wet or too warm? Check those first. If the crying seems unusual, or they have a fever,
      call your pediatrician.
    </p>
    <div class="pt-4">
      <.button type="button" variant="ghost" class="w-full" phx-click="close_sheet">
        Close
      </.button>
    </div>
    """
  end

  ## Copy --------------------------------------------------------------------

  defp week_label(0), do: "first week"
  defp week_label(week), do: "week #{week}"

  defp blurb(:newborn),
    do:
      "Feed about every 2.5–3 hours, practise feed → awake time → sleep when it's easy, and catch sleepy cues before they tip into overtired."

  defp blurb(:foundations),
    do:
      "Sleep cycles are maturing and wake windows are getting longer. Keep watching both the cues and the clock."

  defp blurb(_phase), do: "Keep watching cues and the clock."

  defp cues_line(%{week: %{sleeps: 0}}), do: nil

  defp cues_line(%{week: %{cued: 0}}),
    do:
      "Tap Tired, Ready or Overtired on the Sleep card before a sleep to see when they're ready."

  defp cues_line(%{week: %{cued: cued, sleeps: sleeps, overtired: overtired}}) do
    base = "Cues noted on #{cued} of #{sleeps} sleeps this week"
    if overtired > 0, do: "#{base}, #{overtired} started overtired.", else: base <> "."
  end

  defp windows_line(%{cue_windows: windows}) when map_size(windows) == 0, do: nil

  defp windows_line(%{cue_windows: windows}) do
    parts =
      for cue <- Cue.all(), %{median_seconds: seconds} <- [windows[cue.id]] do
        "#{cue.label} #{format_duration(seconds)}"
      end

    "Typical time awake before sleep this week: " <> Enum.join(parts, " · ")
  end

  defp feed_sleep_line(%{today: %{measured: m, fed_to_sleep: n}}) when m > 0,
    do: "#{n} of #{m} sleeps today began within #{minutes()} of a feed."

  defp feed_sleep_line(%{week: %{measured: m, fed_to_sleep: n}}) when m > 0,
    do: "#{n} of #{m} sleeps this week began within #{minutes()} of a feed."

  defp feed_sleep_line(_habits), do: nil

  defp minutes, do: "#{div(SleepHabits.fed_to_sleep_seconds(), 60)} minutes"

  defp time_to_go(days) when days >= 14, do: "about #{div(days, 7)} weeks to go"
  defp time_to_go(1), do: "1 day to go"
  defp time_to_go(days), do: "#{days} days to go"
end
