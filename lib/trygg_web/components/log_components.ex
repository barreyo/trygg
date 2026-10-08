defmodule TryggWeb.LogComponents do
  @moduledoc """
  Presentational components and formatting helpers for the shared child log.
  """
  use Phoenix.Component

  import Phoenix.LiveView, only: [consume_uploaded_entries: 3, cancel_upload: 3]
  import TryggWeb.CoreComponents, only: [icon: 1, button: 1, input: 1, sheet_frame: 1]

  alias Trygg.Accounts.Scope
  alias Trygg.Accounts.User
  alias Trygg.Families.Child
  alias Trygg.Log
  alias Trygg.Log.Entry
  alias Trygg.Units

  @doc """
  A compact 'time since last X' stat card.

  Content is laid out top-to-bottom in order of importance — label, value,
  supporting line, then an optional tone-coloured status line — and every line
  wraps rather than truncates, so nothing is hidden on narrow screens. Cards in
  the same grid row stretch to equal height.
  """
  attr :icon, :string, default: nil, doc: "heroicon name; ignored when :emoji is given"
  attr :emoji, :string, default: nil, doc: "emoji glyph, shown instead of an icon"
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :sub, :string, default: nil, doc: "neutral supporting line, e.g. \"Next ≈ 14:10\""

  attr :status, :string,
    default: nil,
    doc: "short call-out rendered in the card's tone colour, e.g. \"40m later than usual\""

  attr :today, :string,
    default: nil,
    doc: "quiet running total for the day, e.g. \"4 feeds · 215 ml today\""

  attr :badge, :string, default: nil
  attr :badge_label, :string, default: nil
  attr :badge_id, :string, default: nil
  attr :tone, :string, default: "base", values: ~w(base warning success)

  attr :category, :string,
    default: nil,
    values: [nil, "feed", "diaper", "sleep"],
    doc:
      "subtle identity tint for the card's resting state, so it's recognizable by colour alone; overridden by :tone when there's something to call out"

  def since_card(assigns) do
    ~H"""
    <div class={[
      "rounded-box p-2 h-full min-w-0 flex flex-col gap-1",
      @tone == "base" && category_bg(@category),
      @tone == "warning" && "bg-warning/15",
      @tone == "success" && "bg-success/10"
    ]}>
      <div class="flex items-center gap-1.5 text-xs opacity-70 min-w-0">
        <span :if={@emoji} class="text-sm leading-none shrink-0" aria-hidden="true">{@emoji}</span>
        <.icon :if={!@emoji && @icon} name={@icon} class="size-4 shrink-0" />
        <span class="truncate">{@label}</span>
      </div>
      <div class="flex items-end justify-between gap-2 min-w-0">
        <div class="min-w-0 flex-1">
          <div class="text-lg sm:text-xl font-semibold leading-tight tabular-nums break-words">
            {@value}
          </div>
          <div :if={@sub} class="text-xs opacity-70 leading-snug break-words mt-0.5">{@sub}</div>
        </div>
        <div :if={@badge} id={@badge_id} class="text-right shrink-0">
          <div class="text-lg font-semibold leading-tight tabular-nums">{@badge}</div>
          <div :if={@badge_label} class="text-xs opacity-60">{@badge_label}</div>
        </div>
      </div>
      <div :if={@today} class="text-xs opacity-70 leading-snug break-words tabular-nums">
        {@today}
      </div>
      <div
        :if={@status}
        class={[
          "mt-auto pt-1 text-xs font-medium leading-snug break-words flex items-start gap-1.5",
          @tone == "warning" && "text-warning",
          @tone == "success" && "text-success",
          @tone == "base" && "opacity-70"
        ]}
      >
        <span class="mt-1.5 size-1.5 rounded-full bg-current shrink-0" aria-hidden="true"></span>
        <span>{@status}</span>
      </div>
    </div>
    """
  end

  @doc """
  The big, friendly "at a glance" card on the Home screen: a bubble with the
  category's emoji, a small label, a big value, a supporting line, and a pill
  for anything worth calling out, with today's running total underneath.

  This is Home's own card; `since_card/1` stays the compact stat card used on
  Vitals, Reports and the printed PDF. Same content model (label, value, sub,
  status, today, tone) so the two stay easy to swap, but roomy and playful:
  generous padding, large type, a tinted gradient and a soft "toy" edge in the
  category colour. Cards stack full width, since big text doesn't fit three
  across a phone. The look lives in the `.glance-*` rules in app.css.
  """
  attr :emoji, :string, required: true, doc: "emoji glyph shown in the bubble"
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :sub, :string, default: nil, doc: "neutral supporting line, e.g. \"Next ≈ 14:10\""
  attr :status, :string, default: nil, doc: "call-out pill, e.g. \"40m later than usual\""
  attr :today, :string, default: nil, doc: "running total for the day"
  attr :tone, :string, default: "base", values: ~w(base warning success)

  attr :category, :string,
    default: nil,
    values: [nil, "feed", "diaper", "sleep"],
    doc: "picks the card's resting tint; :tone overrides it when there's something to call out"

  attr :snooze, :boolean, default: false, doc: "drift a little Zzz off the bubble (asleep)"
  attr :index, :integer, default: 0, doc: "position in the stack, for the staggered entrance"

  def glance_card(assigns) do
    ~H"""
    <div
      class={["glance-card glance-pop", @category && "glance-#{@category}"]}
      data-tone={@tone}
      style={"--d: #{@index * 80}ms"}
    >
      <div class="flex items-center gap-4">
        <span class="glance-bubble" style={"--bob-delay: #{@index * 700}ms"} aria-hidden="true">
          {@emoji}
          <span :if={@snooze} class="snooze glance-snooze"><i>z</i><i>z</i><i>z</i></span>
        </span>
        <div class="min-w-0 flex-1">
          <div class="text-sm font-bold uppercase tracking-wider opacity-70">{@label}</div>
          <div class="text-3xl font-extrabold leading-tight tabular-nums break-words">
            {@value}
          </div>
          <div :if={@sub} class="mt-0.5 text-base leading-snug opacity-80 break-words">{@sub}</div>
        </div>
      </div>
      <div :if={@status || @today} class="mt-4 flex flex-wrap items-center gap-x-3 gap-y-2">
        <span :if={@status} class="glance-pill">{@status}</span>
        <span :if={@today} class="text-sm leading-snug opacity-70 tabular-nums">{@today}</span>
      </div>
    </div>
    """
  end

  defp category_bg("feed"), do: "bg-info/10"
  defp category_bg("diaper"), do: "tint-diaper"
  defp category_bg("sleep"), do: "bg-primary/10"
  defp category_bg(_), do: "bg-base-200"

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
    <div class="glance-pop rounded-[1.75rem] bg-primary text-primary-content shadow-lg overflow-hidden">
      <div class="p-5 flex items-center gap-4">
        <span class="glance-bubble glance-bubble-solid" aria-hidden="true">
          <.icon name={entry_icon(@entry.type)} class="size-8" />
        </span>
        <div class="flex-1 min-w-0">
          <div class="text-base font-semibold opacity-90">
            {running_label(@entry)}<span :if={@since_label}> · since {@since_label}</span>
          </div>
          <div
            id={"timer-#{@entry.id}"}
            phx-hook="Timer"
            data-since={DateTime.to_unix(@entry.started_at)}
            class="text-4xl font-extrabold leading-tight tabular-nums"
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

  @doc "Marks a feed that included the day's vitamin D drop."
  def vitamin_d_badge(assigns) do
    ~H"""
    <span
      data-vitamin-d
      class="badge badge-warning badge-sm shrink-0 gap-1 whitespace-nowrap font-medium"
    >
      <span aria-hidden="true">☀️</span> Vitamin D
    </span>
    """
  end

  @doc """
  The "vitamin D drop given" checkbox for a bottle form. Posts `entry[vitamin_d]`
  as `"true"` when ticked and `"false"` otherwise.
  """
  attr :checked, :boolean, default: false
  attr :id, :string, default: "vitamin-d-field"

  def vitamin_d_field(assigns) do
    ~H"""
    <label
      id={@id}
      class="flex items-center gap-3 rounded-box bg-warning/10 px-3 py-2.5 cursor-pointer"
    >
      <input type="hidden" name="entry[vitamin_d]" value="false" />
      <input
        type="checkbox"
        name="entry[vitamin_d]"
        value="true"
        checked={@checked}
        class="checkbox checkbox-warning"
      />
      <span class="font-medium"><span aria-hidden="true">☀️</span> Vitamin D drop given</span>
    </label>
    """
  end

  @doc "One row in a timeline / recent list."
  attr :entry, Entry, required: true
  attr :unit_system, :atom, default: :metric
  attr :tz, :string, default: "Etc/UTC", doc: "the child's IANA time zone, for the timestamp"
  attr :on_click, :any, default: nil
  attr :show_date, :boolean, default: false
  attr :photo_src, :string, default: nil, doc: "URL for the entry's photo, when it has one"
  attr :rest, :global

  def entry_row(assigns) do
    ~H"""
    <div class={["py-3", @on_click && "cursor-pointer"]} phx-click={@on_click} {@rest}>
      <div class="flex items-center gap-3">
        <div class="size-9 rounded-full grid place-items-center shrink-0 bg-base-200">
          <span
            :if={@entry.type == :diaper}
            class="text-base leading-none"
            aria-hidden="true"
          >
            {diaper_emoji(@entry.data["kind"])}
          </span>
          <.icon
            :if={@entry.type != :diaper}
            name={entry_icon(@entry.type)}
            class={
              "size-5 #{entry_icon_color(@entry.type)}" <>
                if(asleep_now?(@entry), do: " motion-safe:animate-pulse", else: "")
            }
          />
        </div>
        <div class="flex-1 min-w-0">
          <%= if asleep_now?(@entry) do %>
            <div class="font-semibold text-primary flex items-center gap-1 leading-tight">
              Sleeping <span class="snooze" aria-hidden="true"><i>z</i><i>z</i><i>z</i></span>
            </div>
          <% else %>
            <div class="flex items-center gap-2 min-w-0">
              <div class="font-semibold leading-tight truncate">
                {entry_title(@entry, @unit_system)}
              </div>
              <.vitamin_d_badge :if={Entry.vitamin_d?(@entry)} />
            </div>
            <div
              :if={entry_detail(@entry, @unit_system)}
              class="mt-0.5 text-sm opacity-60 leading-tight truncate"
            >
              {entry_detail(@entry, @unit_system)}
            </div>
          <% end %>
        </div>
        <div class="text-right shrink-0 leading-tight">
          <div class="text-sm font-semibold tabular-nums opacity-90 whitespace-nowrap">
            {if @show_date,
              do: stamp(@entry.started_at, @tz),
              else: clock(@entry.started_at, @tz)}
          </div>
          <div
            :if={Entry.logged_by_integration?(@entry)}
            class="mt-0.5 flex items-center justify-end gap-1 text-xs opacity-60 truncate max-w-24"
            title={"Logged by an integration: #{@entry.logged_via}"}
            data-logged-by="integration"
          >
            <.icon name="hero-bolt" class="size-3 shrink-0" /> Other
          </div>
          <div :if={@entry.logged_by} class="mt-0.5 text-xs opacity-60 truncate max-w-24">
            {User.capitalize_name(@entry.logged_by.first_name)}
          </div>
        </div>
      </div>

      <img
        :if={@photo_src}
        src={@photo_src}
        loading="lazy"
        alt={"Photo attached to this #{entry_noun(@entry)}"}
        class="mt-2 ml-12 h-40 w-full max-w-56 rounded-lg border border-base-300 bg-base-200 object-cover"
      />
    </div>
    """
  end

  ## Formatting helpers ---------------------------------------------------

  @doc "Heroicon name for an entry type."
  def entry_icon(:feeding), do: "hero-beaker"
  def entry_icon(:diaper), do: "hero-sparkles"
  def entry_icon(:sleep), do: "hero-moon"
  def entry_icon(_), do: "hero-clipboard-document-list"

  # The one accent color that marks an entry's activity type in the timeline
  # row's otherwise-uniform grey circle — same colors as the Home screen's
  # glance cards, so "blue" reads as "feeding" everywhere in the app.
  defp entry_icon_color(:feeding), do: "text-info"
  defp entry_icon_color(:sleep), do: "text-primary"
  defp entry_icon_color(_), do: "opacity-60"

  # {emoji, stored kind, label} — the single source of truth for how each
  # diaper kind is shown, used by the quick buttons, the "log from earlier"
  # sheet, and every log row.
  @diaper_choices [{"💧", "pee", "Pee"}, {"💩", "poo", "Poo"}, {"💧💩", "mixed", "Mixed"}]

  @doc "The diaper kinds as `{emoji, value, label}` triples, in display order."
  def diaper_choices, do: @diaper_choices

  @doc ~S|Emoji for a diaper kind ("pee" / "poo" / "mixed"); a plain diaper pin as a fallback.|
  def diaper_emoji(kind) do
    case Enum.find(@diaper_choices, fn {_e, v, _l} -> v == to_string(kind) end) do
      {emoji, _v, _l} -> emoji
      nil -> "🧷"
    end
  end

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

  def format_duration(seconds) when is_float(seconds), do: format_duration(round(seconds))

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

  ## Edit sheet ----------------------------------------------------------

  @doc """
  Whether the edit sheet should offer the vitamin D checkbox for `entry`: it's a
  feed that already carries the drop (so it can be unticked), or the child's
  reminder is on and no drop was logged on the entry's local day (so a forgotten
  one can be added after the fact).
  """
  @spec offer_vitamin_d?(Child.t(), Entry.t()) :: boolean()
  def offer_vitamin_d?(%Child{} = child, %Entry{type: :feeding} = entry) do
    Entry.vitamin_d?(entry) or
      (child.vitamin_d_reminder and
         not Log.vitamin_d_given?(child, local_date(child, entry.started_at)))
  end

  def offer_vitamin_d?(_child, _entry), do: false

  defp local_date(%Child{timezone: tz}, %DateTime{} = dt),
    do: dt |> DateTime.shift_zone!(tz) |> DateTime.to_date()

  @doc "Form params for the shared entry edit sheet."
  def entry_edit_params(%Entry{} = e, %Child{} = child) do
    %{
      "started_at" => to_local_input(child, e.started_at),
      "ended_at" => to_local_input(child, e.ended_at),
      "note" => e.note,
      "amount" => amount_display(e),
      "vitamin_d" => to_string(Entry.vitamin_d?(e))
    }
  end

  @doc """
  Applies the edit-sheet params to an entry. Returns `{:ok, entry}`,
  `{:error, %Ecto.Changeset{}}`, or `{:error, :invalid_time}`.

  Photo changes are passed in `params`: `"photo_key"` / `"photo_content_type"`
  (a freshly stored upload) replace the photo, and `"remove_photo" => "true"`
  clears it. Absent those keys, the existing photo is left untouched.
  """
  def save_entry_edit(%Scope{} = scope, %Entry{} = entry, %Child{} = child, params) do
    case local_to_utc(child, params["started_at"]) do
      {:ok, started_at} ->
        # feeds and diapers are instantaneous: keep ended_at pinned to started_at
        ended_at =
          if entry.type == :sleep do
            case local_to_utc(child, params["ended_at"]) do
              {:ok, dt} -> dt
              _ -> nil
            end
          else
            started_at
          end

        attrs =
          %{
            "type" => to_string(entry.type),
            "started_at" => started_at,
            "ended_at" => ended_at,
            "note" => params["note"],
            "data" => merge_data(entry, params)
          }
          |> Map.merge(photo_attrs(params))

        Log.update_entry(scope, entry, attrs)

      :error ->
        {:error, :invalid_time}
    end
  end

  # New upload wins; otherwise an explicit "remove" clears both columns;
  # otherwise leave the photo out of the update entirely.
  defp photo_attrs(%{"photo_key" => key} = params) when is_binary(key) and key != "" do
    %{"photo_key" => key, "photo_content_type" => params["photo_content_type"]}
  end

  defp photo_attrs(%{"remove_photo" => "true"}),
    do: %{"photo_key" => nil, "photo_content_type" => nil}

  defp photo_attrs(_params), do: %{}

  @doc """
  Consumes a pending `:photo` upload into stored bytes, returning attrs to
  merge into a `Trygg.Log` create/update call (`"photo_key"` /
  `"photo_content_type"`), or `%{}` when nothing is attached.
  """
  # `path` is the LiveView-managed upload temp file, not request-controlled.
  # sobelow_skip ["Traversal.FileModule"]
  def consume_photo(socket, %Child{} = child) do
    socket
    |> consume_uploaded_entries(:photo, fn %{path: path}, entry ->
      with {:ok, binary} <- File.read(path),
           {:ok, attrs} <- Log.store_photo(child, binary, entry.client_type) do
        {:ok, attrs}
      else
        _ -> {:postpone, %{}}
      end
    end)
    |> case do
      [%{"photo_key" => _} = attrs | _] -> attrs
      _ -> %{}
    end
  end

  @doc "Cancels any pending `:photo` upload so it can't leak into another form."
  def clear_photo_upload(socket) do
    Enum.reduce(socket.assigns.uploads.photo.entries, socket, fn entry, acc ->
      cancel_upload(acc, :photo, entry.ref)
    end)
  end

  @doc """
  Turns an upload error atom (from `Phoenix.Component.upload_errors/2`) into a
  short, human sentence.
  """
  def upload_error_to_string(:too_large), do: "That photo is too large (15 MB max)."
  def upload_error_to_string(:too_many_files), do: "One photo at a time, please."
  def upload_error_to_string(:not_accepted), do: "That file isn't an image we can show."
  def upload_error_to_string(_), do: "That photo couldn't be added — try another."

  @doc """
  True while a valid photo is still streaming to the server — used to hold the
  save button until the upload lands so the entry never saves without its photo.
  """
  def photo_uploading?(%Phoenix.LiveView.UploadConfig{} = upload) do
    Enum.any?(upload.entries, &(&1.valid? and not &1.done?))
  end

  @doc """
  The primary submit button for a log form. It narrates what's happening:
  while a photo is still uploading it's held disabled ("Waiting for photo…"),
  and once submitted it swaps to a spinner + `saving_label` (via the
  `phx-submit-loading` class LiveView puts on the button during the round trip).
  """
  attr :label, :string, required: true
  attr :saving_label, :string, default: "Saving…"
  attr :uploading?, :boolean, default: false
  attr :class, :any, default: nil

  def save_button(assigns) do
    ~H"""
    <.button type="submit" variant="primary" disabled={@uploading?} class={@class}>
      <span class={[
        "loading loading-spinner loading-sm",
        !@uploading? && "hidden phx-submit-loading:inline-block"
      ]}></span>
      <span :if={@uploading?}>Waiting for photo…</span>
      <span :if={!@uploading?} class="phx-submit-loading:hidden">{@label}</span>
      <span :if={!@uploading?} class="hidden phx-submit-loading:inline">{@saving_label}</span>
    </.button>
    """
  end

  @doc """
  The photo picker shared by the log sheets and the edit modal: any current
  photo with a "remove" toggle, a live preview of a pending upload, and the
  file input itself.
  """
  attr :upload, Phoenix.LiveView.UploadConfig, required: true
  attr :current_src, :string, default: nil, doc: "URL of the already-attached photo, if any"
  attr :removable, :boolean, default: false, doc: "show the 'remove photo' toggle"

  def photo_field(assigns) do
    ~H"""
    <div class="fieldset mb-2" phx-drop-target={@upload.ref}>
      <span class="label mb-1">Photo <span class="opacity-60">(optional)</span></span>

      <div :if={@current_src && @upload.entries == []} class="mb-2 space-y-1">
        <img
          src={@current_src}
          alt="Attached photo"
          class="h-36 w-full max-w-48 rounded-lg border border-base-300 object-cover"
        />
        <label :if={@removable} class="flex cursor-pointer items-center gap-2 text-sm">
          <input type="checkbox" name="entry[remove_photo]" value="true" class="checkbox checkbox-sm" />
          <span>Remove photo</span>
        </label>
      </div>

      <div :for={entry <- @upload.entries} class="mb-2 space-y-1.5">
        <div class="relative w-full max-w-48">
          <.live_img_preview
            entry={entry}
            class={[
              "h-36 w-full rounded-lg border border-base-300 object-cover transition-opacity",
              not entry.done? && "opacity-50"
            ]}
          />
          <div
            :if={entry.valid? and not entry.done?}
            class="absolute inset-0 grid place-items-center rounded-lg bg-black/25"
          >
            <span class="loading loading-spinner loading-md text-white"></span>
          </div>
        </div>

        <div :if={entry.valid? and not entry.done?}>
          <progress
            class="progress progress-primary h-1.5 w-full max-w-48"
            value={entry.progress}
            max="100"
          ></progress>
          <p class="text-xs opacity-70">Uploading photo… {entry.progress}%</p>
        </div>

        <p :if={entry.done?} class="flex items-center gap-1 text-xs text-success">
          <.icon name="hero-check-circle" class="size-4" /> Photo attached
        </p>

        <button
          type="button"
          phx-click="cancel_photo"
          phx-value-ref={entry.ref}
          class="text-sm text-error hover:underline"
        >
          {if entry.done?, do: "Remove", else: "Cancel upload"}
        </button>
        <p :for={err <- upload_errors(@upload, entry)} class="text-xs text-error">
          {upload_error_to_string(err)}
        </p>
      </div>

      <%!-- No `capture` attribute on purpose: with image MIME types in `accept`,
      leaving it off lets mobile browsers offer both the camera and the existing
      library (iOS shows its Photo Library / Take Photo / Choose File sheet). --%>
      <.live_file_input upload={@upload} class="file-input file-input-bordered w-full" />

      <p :for={err <- upload_errors(@upload)} class="text-xs text-error">
        {upload_error_to_string(err)}
      </p>
    </div>
    """
  end

  attr :entry, Entry, required: true
  attr :form, :any, required: true
  attr :upload, Phoenix.LiveView.UploadConfig, required: true
  attr :photo_src, :string, default: nil
  attr :vitamin_d?, :boolean, default: false, doc: "offer the vitamin D checkbox (feeds only)"

  def edit_modal(assigns) do
    ~H"""
    <.sheet_frame
      id="edit-entry-modal"
      close="cancel_edit"
      label={"Edit this #{entry_noun(@entry)}"}
      modal_back
    >
      <h3 class="font-semibold text-lg mb-3">Edit this {entry_noun(@entry)}</h3>

      <.form
        for={@form}
        id="edit-entry-form"
        phx-change="validate_edit"
        phx-submit="save_edit"
        class="space-y-3"
      >
        <.input field={@form[:started_at]} type="datetime-local" label={time_label(@entry)} />
        <.input
          :if={@entry.type == :sleep}
          field={@form[:ended_at]}
          type="datetime-local"
          label="Ended"
        />
        <.input
          :if={has_amount?(@entry)}
          field={@form[:amount]}
          type="number"
          step="any"
          label="Amount (ml)"
        />
        <.vitamin_d_field
          :if={@vitamin_d?}
          id="edit-vitamin-d"
          checked={@form.params["vitamin_d"] == "true"}
        />
        <.input field={@form[:note]} type="text" label="Note" />

        <.photo_field upload={@upload} current_src={@photo_src} removable={@photo_src != nil} />

        <div class="flex gap-2 pt-1">
          <.save_button
            label="Save"
            saving_label="Saving…"
            uploading?={photo_uploading?(@upload)}
            class="flex-1"
          />
          <.button type="button" variant="ghost" phx-click="cancel_edit">Cancel</.button>
        </div>
        <.button
          id="edit-entry-delete"
          type="button"
          variant="outline"
          size="sm"
          phx-click="delete_entry"
          data-confirm="Delete this entry?"
          class="btn-error w-full mt-2"
        >
          Delete
        </.button>
      </.form>
    </.sheet_frame>
    """
  end

  defp time_label(%Entry{type: :sleep}), do: "Started"
  defp time_label(_), do: "Time"

  defp has_amount?(%Entry{type: :feeding}), do: true
  defp has_amount?(_), do: false

  defp amount_display(%Entry{data: %{"amount_ml" => ml}}) when is_number(ml), do: ml
  defp amount_display(_), do: nil

  defp merge_data(%Entry{data: data} = e, params) do
    data = data || %{}

    data =
      case {has_amount?(e), parse_number(params["amount"])} do
        {true, n} when is_number(n) -> Map.put(data, "amount_ml", n)
        _ -> data
      end

    # The checkbox is only offered on some feeds; an absent field leaves the
    # data alone.
    case params["vitamin_d"] do
      "true" -> Map.put(data, "vitamin_d", true)
      "false" -> Map.delete(data, "vitamin_d")
      _ -> data
    end
  end

  defp to_local_input(_child, nil), do: nil
  defp to_local_input(%Child{} = child, %DateTime{} = dt), do: Child.to_local_input(child, dt)

  defp local_to_utc(_child, blank) when blank in [nil, ""], do: {:ok, nil}
  defp local_to_utc(%Child{} = child, value), do: Child.from_local_input(child, value)

  defp parse_number(nil), do: nil
  defp parse_number(""), do: nil

  defp parse_number(s) when is_binary(s) do
    case Float.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_number(n) when is_number(n), do: n
end
