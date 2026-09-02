defmodule TryggWeb.LogComponents do
  @moduledoc """
  Presentational components and formatting helpers for the shared child log.
  """
  use Phoenix.Component

  import TryggWeb.CoreComponents, only: [icon: 1, button: 1]

  alias Trygg.Log.Entry
  alias Trygg.Units

  @doc "A compact 'time since last X' stat card."
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :sub, :string, default: nil
  attr :tone, :string, default: "base", values: ~w(base warning success)

  def since_card(assigns) do
    ~H"""
    <div class={[
      "rounded-box border p-3 flex flex-col gap-0.5",
      @tone == "base" && "bg-base-200 border-base-300",
      @tone == "warning" && "bg-warning/10 border-warning/40",
      @tone == "success" && "bg-success/10 border-success/40"
    ]}>
      <div class="flex items-center gap-1.5 text-xs opacity-70">
        <.icon name={@icon} class="size-4" />{@label}
      </div>
      <div class="text-xl font-semibold leading-tight">{@value}</div>
      <div :if={@sub} class="text-xs opacity-60 truncate">{@sub}</div>
    </div>
    """
  end

  @doc """
  The running-timer card: a live-ticking duration, a Stop button, and an
  optional `:controls` slot (rendered inside the same card, on a slightly darker
  sub-bar) for actions that adjust *this* timer.
  """
  attr :entry, Entry, required: true
  attr :can_write, :boolean, default: true
  attr :on_stop, :string, default: "stop_timer", doc: "phx-click event for the Stop button"
  attr :since_label, :string, default: nil, doc: "absolute start time, e.g. \"14:32\""
  slot :controls, doc: "controls that act on this timer; shown on a subtle sub-bar"

  def timer_banner(assigns) do
    ~H"""
    <div class="rounded-box bg-primary text-primary-content shadow-lg overflow-hidden">
      <div class="p-4 flex items-center gap-3">
        <.icon name={entry_icon(@entry.type)} class="size-7 shrink-0" />
        <div class="flex-1 min-w-0">
          <div class="text-sm opacity-80">
            {running_label(@entry)}<span :if={@since_label}> · since {@since_label}</span>
          </div>
          <div
            id={"timer-#{@entry.id}"}
            phx-hook="Timer"
            data-since={DateTime.to_unix(@entry.started_at)}
            class="text-2xl font-bold tabular-nums"
          >
            0s
          </div>
        </div>
        <.button
          :if={@can_write}
          type="button"
          phx-click={@on_stop}
          phx-value-id={@entry.id}
          class="bg-primary-content text-primary border-0 hover:bg-primary-content hover:brightness-95"
        >
          Stop
        </.button>
      </div>

      <div
        :if={@controls != []}
        class="flex flex-wrap items-center gap-2 px-4 py-3 bg-black/15"
      >
        {render_slot(@controls)}
      </div>
    </div>
    """
  end

  @doc "Extra classes that style a `<.button>` to sit on the primary-colored timer card."
  def timer_control_class do
    "bg-primary-content/15 text-primary-content border-primary-content/25 " <>
      "hover:bg-primary-content/30 hover:border-primary-content/40"
  end

  @doc "One row in a timeline / recent list."
  attr :entry, Entry, required: true
  attr :unit_system, :atom, default: :metric
  attr :tz, :string, default: "Etc/UTC", doc: "the child's IANA time zone, for the timestamp"
  attr :on_click, :any, default: nil
  attr :show_date, :boolean, default: false
  attr :rest, :global

  def entry_row(assigns) do
    ~H"""
    <div
      class={[
        "flex items-start gap-3 py-3",
        @on_click && "cursor-pointer active:bg-base-200 -mx-2 px-2 rounded-lg"
      ]}
      phx-click={@on_click}
      {@rest}
    >
      <div class={[
        "mt-0.5 size-9 rounded-full grid place-items-center shrink-0",
        if(asleep_now?(@entry), do: "bg-primary/15 text-primary", else: "bg-base-200")
      ]}>
        <.icon
          name={entry_icon(@entry.type)}
          class={"size-5 " <> if(asleep_now?(@entry), do: "motion-safe:animate-pulse", else: "")}
        />
      </div>
      <div class="flex-1 min-w-0">
        <%= if asleep_now?(@entry) do %>
          <div class="font-medium text-primary flex items-center gap-1">
            Sleeping <span class="snooze" aria-hidden="true"><i>z</i><i>z</i><i>z</i></span>
          </div>
        <% else %>
          <div class="font-medium">{entry_title(@entry, @unit_system)}</div>
          <div :if={entry_detail(@entry, @unit_system)} class="text-sm opacity-70">
            {entry_detail(@entry, @unit_system)}
          </div>
        <% end %>
      </div>
      <div class="text-right shrink-0">
        <div class="text-sm opacity-70 whitespace-nowrap">
          {if @show_date,
            do: stamp(@entry.started_at, @tz),
            else: clock(@entry.started_at, @tz)}
        </div>
        <div :if={@entry.logged_by} class="text-xs opacity-40 truncate max-w-24">
          {short_email(@entry.logged_by.email)}
        </div>
      </div>
    </div>
    """
  end

  ## Formatting helpers ---------------------------------------------------

  @doc "Heroicon name for an entry type."
  def entry_icon(:feeding), do: "hero-beaker"
  def entry_icon(:diaper), do: "hero-sparkles"
  def entry_icon(:sleep), do: "hero-moon"
  def entry_icon(_), do: "hero-clipboard-document-list"

  @doc ~S(Short, human title for an entry, e.g. "Bottle · 90 ml" or "Slept 1h 12m".)
  def entry_title(%Entry{type: :feeding, data: data}, units) do
    [
      "Bottle",
      contents_label(data["bottle_contents"]),
      Units.format(data["amount_ml"], :volume, units)
    ]
    |> join_dots()
  end

  def entry_title(%Entry{type: :diaper, data: data}, _units) do
    "#{String.capitalize(to_string(data["kind"] || ""))} diaper" |> String.trim()
  end

  def entry_title(%Entry{type: :sleep} = e, _units) do
    cond do
      Entry.running?(e) -> "Sleeping"
      d = short_duration(e) -> "Slept #{d}"
      true -> "Slept"
    end
  end

  def entry_title(%Entry{type: type}, _units), do: type |> to_string() |> String.capitalize()

  @doc "Whether this entry is a child who is asleep right now."
  def asleep_now?(%Entry{type: :sleep} = e), do: Entry.running?(e)
  def asleep_now?(%Entry{}), do: false

  @doc ~S(A plain noun for an entry type, e.g. "sleep" / "feed" / "diaper".)
  def entry_noun(%Entry{type: :sleep}), do: "sleep"
  def entry_noun(%Entry{type: :feeding}), do: "feed"
  def entry_noun(%Entry{type: :diaper}), do: "diaper"
  def entry_noun(%Entry{type: type}), do: to_string(type)

  @doc "Secondary line for an entry (location, colour, note), or nil."
  def entry_detail(%Entry{type: :sleep, data: data, note: note}, _units) do
    [location_label(data["location"]), note] |> compact_join(" · ")
  end

  def entry_detail(%Entry{type: :diaper, data: data, note: note}, _units) do
    [data["color"], data["consistency"], note] |> compact_join(" · ")
  end

  def entry_detail(%Entry{note: note}, _units), do: presence(note)

  @doc "A `HH:MM` clock for a UTC datetime, in the given IANA time zone."
  def clock(%DateTime{} = dt, tz \\ "Etc/UTC") do
    dt |> DateTime.shift_zone!(tz) |> Calendar.strftime("%H:%M")
  end

  @doc "A `Mon 1 Sep · HH:MM` stamp for a UTC datetime, in the given IANA time zone."
  def stamp(%DateTime{} = dt, tz \\ "Etc/UTC") do
    dt |> DateTime.shift_zone!(tz) |> Calendar.strftime("%a %-d %b · %H:%M")
  end

  @doc "Relative distance from now, e.g. \"just now\", \"3h 12m ago\", \"2d ago\"."
  def relative_time(nil), do: "—"

  def relative_time(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds < 45 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h #{rem(div(seconds, 60), 60)}m ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  @doc "Formats a duration in seconds as \"1h 12m\" / \"12m\" / \"45s\"."
  def format_duration(nil), do: "—"

  def format_duration(seconds) when is_integer(seconds) do
    h = div(seconds, 3600)
    m = rem(div(seconds, 60), 60)
    s = rem(seconds, 60)

    cond do
      h > 0 -> "#{h}h #{m}m"
      m > 0 -> "#{m}m"
      true -> "#{s}s"
    end
  end

  def short_email(email) when is_binary(email), do: email |> String.split("@") |> hd()
  def short_email(_), do: ""

  # Formatted duration, or nil for anything under a minute / still open.
  defp short_duration(%Entry{ended_at: nil}), do: nil

  defp short_duration(%Entry{} = e) do
    case Entry.duration_seconds(e) do
      secs when secs < 60 -> nil
      secs -> format_duration(secs)
    end
  end

  defp running_label(%Entry{type: :sleep}), do: "Asleep"
  defp running_label(_), do: "Timer running"

  defp contents_label("formula"), do: "formula"
  defp contents_label("expressed"), do: "expressed milk"
  defp contents_label("donor"), do: "donor milk"
  defp contents_label(_), do: nil

  defp location_label(nil), do: nil
  defp location_label(loc), do: "in " <> to_string(loc)

  defp join_dots(parts) do
    parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")
  end

  defp compact_join(parts, sep) do
    case parts |> Enum.map(&presence/1) |> Enum.reject(&is_nil/1) do
      [] -> nil
      list -> Enum.join(list, sep)
    end
  end

  defp presence(nil), do: nil
  defp presence(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp presence(other), do: other
end
