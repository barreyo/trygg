defmodule TryggWeb.RhythmComponents do
  @moduledoc """
  The Home screen's rhythm dial — a 24-hour clock face that draws the child's
  typical day (night sleep, usual naps), overlays what's actually happened
  today, marks the current time, and puts the single most actionable thing
  (a running timer, the next nap, bedtime) in the middle.

  Fed by `Trygg.Reports.Rhythm` for the ring and a caller-built `center` map
  for the middle. Midnight is at the top; the day runs clockwise.
  """
  use Phoenix.Component

  # Geometry, in the 240×240 viewBox.
  @c 120
  @r_band 92
  @w_band 14
  @r_today 70
  @w_today 6
  @tau 2 * :math.pi()

  @hour_marks [{0, "12a"}, {6 * 60, "6a"}, {12 * 60, "12p"}, {18 * 60, "6p"}]

  @doc """
  Renders the dial.

    * `rhythm` — a `Trygg.Reports.Rhythm.summarize/4` map.
    * `center` — `%{eyebrow, tone, detail}` plus **one** of `big` (a string) or
      `since_unix` (an integer start time the `Timer` hook counts up from).
      `tone` is `:success | :warning | :primary | :base`.
    * `child_name` — used only for the "still learning" hint and a11y text.
  """
  attr :id, :string, default: "rhythm-dial"
  attr :rhythm, :map, required: true
  attr :center, :map, required: true
  attr :child_name, :string, required: true

  def rhythm_dial(assigns) do
    assigns = assign(assigns, :dial, build(assigns.rhythm))

    ~H"""
    <section id={@id} class="mb-6 rounded-box border border-base-300 bg-base-200/40 p-4">
      <div class="relative mx-auto aspect-square w-full max-w-[16rem]">
        <svg
          viewBox="0 0 240 240"
          class="h-full w-full select-none overflow-visible"
          role="img"
          aria-hidden="true"
        >
          <circle
            cx="120"
            cy="120"
            r="92"
            fill="none"
            class="stroke-base-300"
            stroke-width="14"
          />
          <path
            :if={@dial.night}
            d={@dial.night}
            fill="none"
            stroke-linecap="round"
            stroke-width="14"
            class="stroke-primary/25"
          />
          <path
            :for={nap <- @dial.naps}
            d={nap.path}
            fill="none"
            stroke-linecap="round"
            stroke-width="14"
            class="stroke-secondary/70"
          >
            <title>{nap.title}</title>
          </path>
          <path
            :for={seg <- @dial.today}
            d={seg.path}
            fill="none"
            stroke-linecap="round"
            stroke-width="6"
            class={["stroke-success", seg.running? && "rhythm-pulse"]}
          />
          <g :for={mark <- @dial.marks}>
            <line
              x1={mark.x1}
              y1={mark.y1}
              x2={mark.x2}
              y2={mark.y2}
              class="stroke-base-content/25"
              stroke-width="1.5"
            />
            <text
              x={mark.lx}
              y={mark.ly}
              text-anchor="middle"
              dominant-baseline="middle"
              font-size="9"
              class="fill-base-content/40"
            >
              {mark.label}
            </text>
          </g>
          <line
            x1={@dial.now.x1}
            y1={@dial.now.y1}
            x2={@dial.now.x2}
            y2={@dial.now.y2}
            class="stroke-base-content"
            stroke-width="2.5"
            stroke-linecap="round"
          />
          <circle cx={@dial.now.dx} cy={@dial.now.dy} r="3.5" class="fill-base-content" />
        </svg>

        <div class="absolute inset-0 flex flex-col items-center justify-center px-8 text-center">
          <span class="text-[10px] font-semibold uppercase tracking-wider opacity-55">
            {@center.eyebrow}
          </span>
          <span
            :if={@center[:since_unix]}
            id={"#{@id}-elapsed"}
            phx-hook="Timer"
            data-since={@center.since_unix}
            class={["text-3xl font-bold leading-tight tabular-nums", tone_text(@center.tone)]}
          >
            &nbsp;
          </span>
          <span
            :if={@center[:big]}
            class={["text-3xl font-bold leading-tight tabular-nums", tone_text(@center.tone)]}
          >
            {@center.big}
          </span>
          <span :if={@center[:detail]} class="mt-1 text-xs text-balance opacity-70">
            {@center.detail}
          </span>
        </div>
      </div>

      <p :if={!@rhythm.ready?} class="mt-3 text-center text-xs opacity-60">
        Still learning {@child_name}'s daily rhythm — this fills in as you log.
      </p>
    </section>
    """
  end

  defp tone_text(:success), do: "text-success"
  defp tone_text(:warning), do: "text-warning"
  defp tone_text(:primary), do: "text-primary"
  defp tone_text(_), do: ""

  ## Geometry ----------------------------------------------------------------

  defp build(rhythm) do
    wake = rhythm.wake_minutes
    bed = rhythm.bed_minutes

    %{
      night: arc(bed, wake + 1440, @r_band),
      naps:
        for nap <- rhythm.naps do
          %{
            path: arc(nap.start_minutes, max(nap.end_minutes, nap.start_minutes + 6), @r_band),
            title:
              "Nap #{nap.ordinal} · usually #{hhmm(nap.start_minutes)}–#{hhmm(nap.end_minutes)}"
          }
        end,
      today:
        for seg <- rhythm.today, seg.end_minutes - seg.start_minutes > 0.5 do
          %{path: arc(seg.start_minutes, seg.end_minutes, @r_today), running?: seg.running?}
        end,
      marks:
        for {minutes, label} <- @hour_marks do
          {x1, y1} = point(minutes, @r_band - @w_band / 2 - 3)
          {x2, y2} = point(minutes, @r_band + @w_band / 2 + 3)
          {lx, ly} = point(minutes, @r_band + @w_band / 2 + 13)
          %{x1: f(x1), y1: f(y1), x2: f(x2), y2: f(y2), lx: f(lx), ly: f(ly), label: label}
        end,
      now: now_marker(rhythm.now_minutes)
    }
  end

  defp now_marker(minutes) do
    {x1, y1} = point(minutes, @r_today - @w_today / 2 - 6)
    {x2, y2} = point(minutes, @r_band + @w_band / 2 + 4)
    %{x1: f(x1), y1: f(y1), x2: f(x2), y2: f(y2), dx: f(x2), dy: f(y2)}
  end

  # Minutes-from-midnight → an {x, y} on the circle of radius `r`, midnight at
  # the top and the day running clockwise.
  defp point(minutes, r) do
    angle = minutes / 1440 * @tau - @tau / 4
    {@c + r * :math.cos(angle), @c + r * :math.sin(angle)}
  end

  # SVG arc path from `m1` to `m2` (minutes; `m2 > m1`) along radius `r`.
  defp arc(m1, m2, r) when m2 > m1 do
    {x1, y1} = point(m1, r)
    {x2, y2} = point(m2, r)
    large = if (m2 - m1) / 1440 * 360 > 180, do: 1, else: 0
    "M #{f(x1)} #{f(y1)} A #{r} #{r} 0 #{large} 1 #{f(x2)} #{f(y2)}"
  end

  defp arc(_m1, _m2, _r), do: nil

  defp hhmm(minutes) do
    total = minutes |> round() |> Integer.mod(24 * 60)
    :io_lib.format("~2..0B:~2..0B", [div(total, 60), rem(total, 60)]) |> IO.iodata_to_binary()
  end

  defp f(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)
end
