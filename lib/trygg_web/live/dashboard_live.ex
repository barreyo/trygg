defmodule TryggWeb.DashboardLive do
  use TryggWeb, :live_view

  alias Trygg.{Families, Log}
  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias Trygg.Units

  @recent_limit 20
  @tick_ms 60_000
  @nudge_minutes [-5, -15, -30]
  @note_suggestions ["Peaceful", "Restless", "Short one", "Woke a lot"]

  ## Mount / redirect -----------------------------------------------------

  @impl true
  def mount(_params, _session, %{assigns: %{live_action: :index}} = socket) do
    case Families.list_children(socket.assigns.current_scope) do
      [] -> {:ok, push_navigate(socket, to: ~p"/children/new")}
      [child | _] -> {:ok, push_navigate(socket, to: ~p"/c/#{child}")}
    end
  end

  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @tick_ms)

    scope = socket.assigns.current_scope
    child = socket.assigns.current_child

    socket =
      socket
      |> assign(:unit_system, scope.user.unit_system)
      |> assign(:can_write, child.role in [:owner, :caregiver])
      |> assign(:children, Families.list_children(scope))
      |> assign(:sheet, nil)
      |> assign(:sheet_form, nil)
      |> assign(:sheet_amount, 0.0)
      |> assign(:now_tick, System.system_time(:second))
      |> refresh()

    {:ok, socket}
  end

  ## Realtime ---------------------------------------------------------------

  @impl true
  def handle_info({:log, _action, _entry}, socket), do: {:noreply, refresh(socket)}

  def handle_info({:child_updated, child}, socket) do
    {:noreply, assign(socket, :current_child, %{child | role: socket.assigns.role})}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, assign(socket, :now_tick, System.system_time(:second))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Sleep events -------------------------------------------------------

  @impl true
  def handle_event("start_sleep", _params, socket) do
    Log.start_timer(socket.assigns.current_scope, socket.assigns.current_child, :sleep)
    {:noreply, socket}
  end

  def handle_event("nudge_start", %{"by" => by}, socket) do
    minutes = String.to_integer(by)

    socket =
      case running_sleep(socket.assigns) do
        %Entry{} = nap ->
          new_start = DateTime.add(nap.started_at, minutes * 60, :second)

          cond do
            DateTime.compare(new_start, DateTime.utc_now()) == :gt ->
              put_flash(socket, :error, "That would put the start in the future.")

            DateTime.diff(DateTime.utc_now(), new_start, :second) > 86_400 ->
              put_flash(socket, :error, "That's more than a day back — use Edit for that.")

            true ->
              case Log.retime_entry(socket.assigns.current_scope, nap, %{
                     "started_at" => new_start
                   }) do
                {:ok, _} -> socket
                {:error, _} -> put_flash(socket, :error, "Couldn't change the start time.")
              end
          end

        nil ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("request_stop", _params, socket) do
    child = socket.assigns.current_child
    form = to_form(%{"ended_at" => Child.to_local_input(child, now()), "note" => ""}, as: :sleep)
    {:noreply, assign(socket, sheet: :sleep_stop, sheet_form: form)}
  end

  def handle_event("sheet_change", %{"sleep" => params}, socket) do
    {:noreply, assign(socket, :sheet_form, to_form(params, as: :sleep))}
  end

  def handle_event("sheet_change", %{"entry" => params}, socket) do
    {:noreply, assign(socket, :sheet_form, to_form(params, as: :entry))}
  end

  def handle_event("nudge_feed", %{"by" => by}, socket) do
    at = DateTime.add(now(), String.to_integer(by) * 60, :second)

    params =
      socket
      |> current_sheet_params()
      |> Map.put("at", Child.to_local_input(socket.assigns.current_child, at))

    {:noreply, assign(socket, :sheet_form, to_form(params, as: :entry))}
  end

  def handle_event("set_note", %{"text" => text}, socket) do
    params = Map.put(current_sheet_params(socket), "note", text)
    {:noreply, assign(socket, :sheet_form, to_form(params, as: :sleep))}
  end

  def handle_event("save_sleep", %{"sleep" => params}, socket) do
    {:noreply, save_sleep(socket, socket.assigns.sheet, params)}
  end

  ## Other quick actions ---------------------------------------------

  def handle_event("quick", %{"kind" => kind}, socket), do: {:noreply, quick_log(socket, kind)}

  def handle_event("open_sheet", %{"kind" => "bottle"}, socket) do
    last = socket.assigns.summary.last_feeding

    form =
      to_form(
        %{
          "at" => Child.to_local_input(socket.assigns.current_child, now()),
          "bottle_contents" => last_bottle_contents(last),
          "note" => ""
        },
        as: :entry
      )

    socket =
      assign(socket,
        sheet: :bottle,
        sheet_form: form,
        sheet_amount: last_bottle_amount(last, socket.assigns.unit_system)
      )

    {:noreply, socket}
  end

  def handle_event("open_sheet", %{"kind" => "sleep_start"}, socket) do
    case running_sleep(socket.assigns) do
      %Entry{} = nap ->
        form =
          to_form(
            %{"started_at" => Child.to_local_input(socket.assigns.current_child, nap.started_at)},
            as: :sleep
          )

        {:noreply, assign(socket, sheet: :sleep_start, sheet_form: form)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("open_sheet", %{"kind" => "sleep_past"}, socket) do
    child = socket.assigns.current_child
    ended = now()

    started =
      case socket.assigns.summary.last_sleep do
        %Entry{ended_at: %DateTime{} = woke} -> woke
        _ -> DateTime.add(ended, -3600, :second)
      end

    form =
      to_form(
        %{
          "started_at" => Child.to_local_input(child, started),
          "ended_at" => Child.to_local_input(child, ended),
          "note" => ""
        },
        as: :sleep
      )

    {:noreply, assign(socket, sheet: :sleep_past, sheet_form: form)}
  end

  def handle_event("open_sheet", %{"kind" => "diaper_past"}, socket) do
    child = socket.assigns.current_child

    form =
      to_form(
        %{
          "started_at" => Child.to_local_input(child, now()),
          "kind" => "pee",
          "note" => ""
        },
        as: :entry
      )

    {:noreply, assign(socket, sheet: :diaper_past, sheet_form: form)}
  end

  def handle_event("close_sheet", _params, socket) do
    {:noreply, assign(socket, sheet: nil, sheet_form: nil)}
  end

  def handle_event("bump_amount", %{"by" => by}, socket) do
    step = String.to_integer(by)
    {:noreply, update(socket, :sheet_amount, &(max(&1 + step, 0) |> :erlang.float()))}
  end

  def handle_event("save_sheet", %{"entry" => params}, socket) do
    units = socket.assigns.unit_system
    child = socket.assigns.current_child
    ml = Units.from_display(socket.assigns.sheet_amount, :volume, units)

    result =
      with {:ok, at} <- Child.from_local_input(child, params["at"] || ""),
           :ok <- not_future(at) do
        Log.create_entry(socket.assigns.current_scope, child, :feeding, %{
          "type" => "feeding",
          "started_at" => at,
          "data" => %{"bottle_contents" => params["bottle_contents"], "amount_ml" => ml},
          "note" => blank(params["note"])
        })
      end

    {:noreply, settle_feed(socket, result)}
  end

  def handle_event("save_diaper", %{"entry" => params}, socket) do
    child = socket.assigns.current_child

    result =
      with {:ok, started} <- Child.from_local_input(child, params["started_at"] || ""),
           :ok <- not_future(started) do
        Log.create_entry(socket.assigns.current_scope, child, :diaper, %{
          "started_at" => started,
          "data" => %{"kind" => params["kind"]},
          "note" => blank(params["note"])
        })
      end

    {:noreply, settle_diaper(socket, result)}
  end

  defp settle_diaper(socket, {:ok, _}),
    do: socket |> assign(sheet: nil, sheet_form: nil) |> put_flash(:info, "Added that diaper.")

  defp settle_diaper(socket, {:error, :future}),
    do: put_flash(socket, :error, "That's in the future — pick an earlier time.")

  defp settle_diaper(socket, :error),
    do: put_flash(socket, :error, "That date and time didn't look right.")

  defp settle_diaper(socket, {:error, _}),
    do: put_flash(socket, :error, "Hmm, that didn't save — try again.")

  defp settle_feed(socket, {:ok, _}),
    do: socket |> assign(sheet: nil, sheet_form: nil) |> put_flash(:info, "Saved.")

  defp settle_feed(socket, {:error, :future}),
    do: put_flash(socket, :error, "That's in the future — pick an earlier time.")

  defp settle_feed(socket, :error),
    do: put_flash(socket, :error, "That date and time didn't look right.")

  defp settle_feed(socket, {:error, _}),
    do: put_flash(socket, :error, "Pick an amount first.")

  ## Sleep save logic ----------------------------------------------------

  defp save_sleep(socket, :sleep_stop, params) do
    scope = socket.assigns.current_scope

    result =
      with {:ok, ended} <-
             Child.from_local_input(socket.assigns.current_child, params["ended_at"] || ""),
           %Entry{} = nap <- running_sleep(socket.assigns) do
        # a datetime-local field is minute-granular; if the chosen end lands on
        # or before the start (e.g. stopping a nap that began seconds ago), the
        # tap means "now".
        ended = if DateTime.after?(ended, nap.started_at), do: ended, else: now()
        Log.stop_timer(scope, nap, %{"ended_at" => ended, "note" => blank(params["note"])})
      end

    settle(socket, result, "Sleep saved — sweet dreams.")
  end

  defp save_sleep(socket, :sleep_start, params) do
    scope = socket.assigns.current_scope

    result =
      with {:ok, started} <-
             Child.from_local_input(socket.assigns.current_child, params["started_at"] || ""),
           :ok <- not_future(started),
           %Entry{} = nap <- running_sleep(socket.assigns) do
        Log.retime_entry(scope, nap, %{"started_at" => started})
      end

    settle(socket, result, "Updated the start time.")
  end

  defp save_sleep(socket, :sleep_past, params) do
    child = socket.assigns.current_child

    result =
      with {:ok, started} <- Child.from_local_input(child, params["started_at"] || ""),
           {:ok, ended} <- Child.from_local_input(child, params["ended_at"] || "") do
        Log.create_entry(socket.assigns.current_scope, child, :sleep, %{
          "started_at" => started,
          "ended_at" => ended,
          "note" => blank(params["note"])
        })
      end

    settle(socket, result, "Added that sleep.")
  end

  defp settle(socket, {:ok, _}, msg),
    do: socket |> assign(sheet: nil, sheet_form: nil) |> put_flash(:info, msg)

  defp settle(socket, {:error, %Ecto.Changeset{}}, _msg),
    do: put_flash(socket, :error, "Their wake-up time needs to be after they fell asleep.")

  defp settle(socket, {:error, :future}, _msg),
    do: put_flash(socket, :error, "That's in the future — pick an earlier time.")

  defp settle(socket, nil, _msg),
    do: socket |> assign(sheet: nil) |> put_flash(:error, "There's no sleep to update right now.")

  defp settle(socket, :error, _msg),
    do: put_flash(socket, :error, "That date and time didn't look right.")

  ## Helpers ------------------------------------------------------------

  defp quick_log(socket, "diaper_" <> kind) do
    result =
      Log.create_entry(socket.assigns.current_scope, socket.assigns.current_child, :diaper, %{
        "data" => %{"kind" => kind}
      })

    case result do
      {:ok, _} -> put_flash(socket, :info, "Saved.")
      _ -> put_flash(socket, :error, "Hmm, that didn't save — try again.")
    end
  end

  defp refresh(socket) do
    scope = socket.assigns.current_scope
    child = socket.assigns.current_child
    entries = Log.recent_entries(scope, child, @recent_limit)

    socket
    |> assign(:summary, Log.summary(scope, child))
    |> assign(:entries_empty?, entries == [])
    |> stream(:entries, entries, reset: true)
  end

  defp running_sleep(%{summary: %{running: running}}),
    do: Enum.find(running, &(&1.type == :sleep))

  defp current_sheet_params(%{assigns: %{sheet_form: %{params: params}}}) when is_map(params),
    do: params

  defp current_sheet_params(_socket), do: %{}

  defp not_future(dt) do
    if DateTime.compare(dt, now()) == :gt, do: {:error, :future}, else: :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp blank(nil), do: nil

  defp blank(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp preset_steps(:metric), do: [10, 30, 60]
  defp preset_steps(:imperial), do: [1, 2, 4]

  ## Render -------------------------------------------------------------

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} title="Trygg">
      <p class="opacity-60 text-center py-16">Loading…</p>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_child={@current_child}
      title={@current_child.name}
    >
      <:actions>
        <div :if={length(@children) > 1} class="dropdown dropdown-end">
          <.button tabindex="0" type="button" variant="ghost" size="sm" aria-label="Switch child">
            <.icon name="hero-chevron-up-down" class="size-4" />
          </.button>
          <ul tabindex="0" class="dropdown-content menu bg-base-200 rounded-box z-40 w-52 p-2 shadow">
            <li :for={c <- @children}>
              <.link navigate={~p"/c/#{c}"} class={c.id == @current_child.id && "active"}>
                {c.name}
              </.link>
            </li>
          </ul>
        </div>
      </:actions>

      <%!-- Running sleep timer — Stop and start-time fixes live inside this card --%>
      <div :for={entry <- @summary.running} class="mb-6">
        <.timer_banner
          entry={entry}
          can_write={@can_write}
          on_stop="request_stop"
          since_label={Child.local_clock(@current_child, entry.started_at)}
        >
          <:controls :if={@can_write}>
            <span class="text-xs opacity-70 mr-0.5">Started earlier?</span>
            <.button
              :for={m <- nudge_minutes()}
              type="button"
              size="xs"
              phx-click="nudge_start"
              phx-value-by={m}
              class={timer_control_class()}
            >
              {m}m
            </.button>
            <.button
              type="button"
              size="xs"
              phx-click="open_sheet"
              phx-value-kind="sleep_start"
              class={timer_control_class()}
            >
              <.icon name="hero-pencil-square" class="size-3.5" /> Edit
            </.button>
          </:controls>
        </.timer_banner>
      </div>

      <%!-- At a glance --%>
      <section class="rounded-box border border-base-300 bg-base-200/40 p-2 space-y-2">
        <div class="grid grid-cols-3 gap-2">
          <.since_card
            icon="hero-beaker"
            label="Last feed"
            value={relative_time(feed_time(@summary.last_feeding))}
            sub={feed_sub(@summary.last_feeding, @unit_system)}
          />
          <.since_card
            emoji={last_diaper_emoji(@summary.last_diaper)}
            label="Last diaper"
            value={relative_time(time_of(@summary.last_diaper))}
            sub={diaper_sub(@summary.last_diaper)}
          />
          <.since_card
            icon="hero-moon"
            label="Sleep"
            tone={if sleeping?(@summary), do: "warning", else: "base"}
            value={sleep_value(@summary)}
            sub={sleep_sub(@summary)}
          />
        </div>

        <div class="grid grid-cols-3 gap-2 text-center text-sm">
          <div class="rounded-box bg-base-100 border border-base-300 py-2">
            <div class="font-semibold text-lg">{@summary.today.feedings}</div>
            <div class="opacity-60 text-xs">feeds today</div>
          </div>
          <div class="rounded-box bg-base-100 border border-base-300 py-2">
            <div class="font-semibold text-lg">{@summary.today.diapers}</div>
            <div class="opacity-60 text-xs">diapers today</div>
          </div>
          <div class="rounded-box bg-base-100 border border-base-300 py-2">
            <div class="font-semibold text-lg">{format_duration(@summary.today.sleep_seconds)}</div>
            <div class="opacity-60 text-xs">slept today</div>
          </div>
        </div>
      </section>

      <%!-- Log something --%>
      <div :if={@can_write} class="mt-6 space-y-4">
        <div :if={!sleeping?(@summary)} class="space-y-2">
          <.button variant="primary" size="lg" phx-click="start_sleep" class="w-full text-base">
            <.icon name="hero-moon" class="size-5" /> Start sleep
          </.button>
          <.button
            type="button"
            variant="ghost"
            size="sm"
            phx-click="open_sheet"
            phx-value-kind="sleep_past"
            class="w-full"
          >
            <.icon name="hero-plus" class="size-4" /> Add a sleep from earlier
          </.button>
        </div>

        <.button
          type="button"
          size="lg"
          phx-click="open_sheet"
          phx-value-kind="bottle"
          class="w-full text-base"
        >
          <.icon name="hero-beaker" class="size-5" /> Log a bottle
        </.button>

        <div>
          <div class="text-xs opacity-60 mb-1.5">Diaper</div>
          <div class="grid grid-cols-3 gap-2">
            <.action_btn
              :for={{emoji, value, label} <- diaper_choices()}
              kind={"diaper_#{value}"}
              label={label}
              emoji={emoji}
            />
          </div>
          <.button
            type="button"
            variant="ghost"
            size="sm"
            phx-click="open_sheet"
            phx-value-kind="diaper_past"
            class="w-full mt-2"
          >
            <.icon name="hero-plus" class="size-4" /> Add one from earlier
          </.button>
        </div>
      </div>

      <div class="mt-8 flex items-center justify-between border-b border-base-300 pb-2">
        <h2 class="font-semibold">Recent</h2>
        <.link navigate={~p"/c/#{@current_child}/log"} class="text-sm text-primary hover:underline">
          Full log →
        </.link>
      </div>

      <p :if={@entries_empty?} class="opacity-60 text-sm py-6 text-center">
        Nothing tracked yet today — tap a button to start.
      </p>

      <div id="entries" phx-update="stream" class="divide-y divide-base-300">
        <.entry_row
          :for={{dom_id, entry} <- @streams.entries}
          id={dom_id}
          entry={entry}
          unit_system={@unit_system}
          tz={@current_child.timezone}
        />
      </div>

      <.sheet
        :if={@sheet}
        kind={@sheet}
        form={@sheet_form}
        amount={@sheet_amount}
        unit_system={@unit_system}
      />
    </Layouts.app>
    """
  end

  ## Small render components ---------------------------------------------

  attr :kind, :string, required: true
  attr :label, :string, required: true
  attr :emoji, :string, required: true

  defp action_btn(assigns) do
    ~H"""
    <.button type="button" phx-click="quick" phx-value-kind={@kind} class="h-auto py-3 flex-col gap-1">
      <span class="text-2xl leading-none" aria-hidden="true">{@emoji}</span>
      <span class="text-xs font-medium">{@label}</span>
    </.button>
    """
  end

  attr :kind, :atom, required: true
  attr :form, :any, default: nil
  attr :amount, :float, required: true
  attr :unit_system, :atom, required: true

  defp sheet(assigns) do
    assigns = assign(assigns, :unit, Units.unit_label(:volume, assigns.unit_system))

    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-end sm:items-center justify-center"
      phx-window-keydown="close_sheet"
      phx-key="escape"
    >
      <div class="absolute inset-0 bg-black/60" phx-click="close_sheet"></div>
      <div class="relative w-full sm:max-w-md bg-base-100 border-t border-base-300 sm:border sm:rounded-box rounded-t-2xl p-5 pb-[calc(env(safe-area-inset-bottom)+1.25rem)] max-h-[90dvh] overflow-y-auto">
        <%= case @kind do %>
          <% :bottle -> %>
            <h3 class="font-semibold text-lg mb-3">Log a bottle</h3>
            <.form
              for={@form}
              id="bottle-form"
              phx-change="sheet_change"
              phx-submit="save_sheet"
              class="space-y-4"
            >
              <div>
                <div class="text-3xl font-bold text-center tabular-nums">
                  {trim(@amount)} <span class="text-base font-normal opacity-60">{@unit}</span>
                </div>
                <div class="flex gap-2 justify-center mt-2">
                  <.button
                    :for={step <- preset_steps(@unit_system)}
                    type="button"
                    variant="outline"
                    size="sm"
                    phx-click="bump_amount"
                    phx-value-by={step}
                  >
                    +{step}
                  </.button>
                  <.button
                    type="button"
                    variant="ghost"
                    size="sm"
                    phx-click="bump_amount"
                    phx-value-by={neg_all(@amount)}
                  >
                    Reset
                  </.button>
                </div>
              </div>

              <select name="entry[bottle_contents]" class="select select-bordered w-full">
                <option
                  :for={c <- Entry.bottle_contents()}
                  value={c}
                  selected={c == @form.params["bottle_contents"]}
                >
                  {contents_option_label(c)}
                </option>
              </select>

              <div>
                <div class="flex flex-wrap gap-2 mb-2">
                  <.button
                    :for={{label, mins} <- feed_offsets()}
                    type="button"
                    variant="outline"
                    size="xs"
                    phx-click="nudge_feed"
                    phx-value-by={mins}
                  >
                    {label}
                  </.button>
                </div>
                <.input field={@form[:at]} type="datetime-local" label="When" />
              </div>

              <input
                type="text"
                name="entry[note]"
                value={@form.params["note"]}
                placeholder="Note (optional)"
                class="input input-bordered w-full"
              />

              <.sheet_buttons save="Save" />
            </.form>
          <% :sleep_stop -> %>
            <h3 class="font-semibold text-lg mb-3">How did they sleep?</h3>
            <.form
              for={@form}
              id="sleep-form"
              phx-change="sheet_change"
              phx-submit="save_sleep"
              class="space-y-4"
            >
              <.input field={@form[:ended_at]} type="datetime-local" label="Woke up at" />
              <.note_field form={@form} />
              <.sheet_buttons save="Save sleep" />
            </.form>
          <% :sleep_start -> %>
            <h3 class="font-semibold text-lg mb-3">When did they fall asleep?</h3>
            <.form for={@form} id="sleep-form" phx-submit="save_sleep" class="space-y-4">
              <.input field={@form[:started_at]} type="datetime-local" label="Fell asleep at" />
              <.sheet_buttons save="Save" />
            </.form>
          <% :sleep_past -> %>
            <h3 class="font-semibold text-lg mb-3">Add a sleep from earlier</h3>
            <.form
              for={@form}
              id="sleep-form"
              phx-change="sheet_change"
              phx-submit="save_sleep"
              class="space-y-4"
            >
              <.input field={@form[:started_at]} type="datetime-local" label="Fell asleep" />
              <.input field={@form[:ended_at]} type="datetime-local" label="Woke up" />
              <.note_field form={@form} />
              <.sheet_buttons save="Add sleep" />
            </.form>
          <% :diaper_past -> %>
            <h3 class="font-semibold text-lg mb-3">Add a diaper from earlier</h3>
            <.form for={@form} id="diaper-form" phx-submit="save_diaper" class="space-y-4">
              <div class="join w-full">
                <input
                  :for={{emoji, value, label} <- diaper_choices()}
                  type="radio"
                  name="entry[kind]"
                  value={value}
                  aria-label={"#{emoji} #{label}"}
                  checked={value == @form.params["kind"]}
                  class="join-item btn flex-1"
                />
              </div>
              <.input field={@form[:started_at]} type="datetime-local" label="When" />
              <.input
                field={@form[:note]}
                type="text"
                label="Note"
                placeholder="Anything to remember? (optional)"
              />
              <.sheet_buttons save="Add diaper" />
            </.form>
        <% end %>
      </div>
    </div>
    """
  end

  attr :form, :any, required: true

  defp note_field(assigns) do
    ~H"""
    <div>
      <div class="flex flex-wrap gap-2 mb-2">
        <.button
          :for={n <- note_suggestions()}
          type="button"
          variant="outline"
          size="xs"
          phx-click="set_note"
          phx-value-text={n}
        >
          {n}
        </.button>
      </div>
      <.input
        field={@form[:note]}
        type="text"
        label="Note"
        placeholder="Anything to remember? (optional)"
      />
    </div>
    """
  end

  attr :save, :string, required: true

  defp sheet_buttons(assigns) do
    ~H"""
    <div class="flex gap-2 pt-1">
      <.button type="submit" variant="primary" class="flex-1">{@save}</.button>
      <.button type="button" variant="ghost" phx-click="close_sheet">Cancel</.button>
    </div>
    """
  end

  ## Presentation helpers ----------------------------------------------

  defp nudge_minutes, do: @nudge_minutes
  defp note_suggestions, do: @note_suggestions

  # Emoji for the "Last diaper" card — the most recent diaper's kind, or a
  # neutral pin when nothing's been logged yet. `diaper_choices/0` /
  # `diaper_emoji/1` come from TryggWeb.LogComponents so every surface agrees.
  defp last_diaper_emoji(%Entry{data: %{"kind" => k}}), do: diaper_emoji(k)
  defp last_diaper_emoji(_), do: diaper_emoji(nil)

  # {label, minutes-from-now} one-tap chips for back-dating a bottle.
  defp feed_offsets,
    do: [{"Now", 0}, {"15m ago", -15}, {"30m ago", -30}, {"1h ago", -60}, {"2h ago", -120}]

  defp contents_option_label("formula"), do: "Formula"
  defp contents_option_label("expressed"), do: "Expressed milk"
  defp contents_option_label("donor"), do: "Donor milk"
  defp contents_option_label(other), do: String.capitalize(to_string(other))

  # Seed the bottle sheet from the last feed so caregivers rarely have to adjust.
  defp last_bottle_amount(%Entry{data: %{"amount_ml" => ml}}, units) when is_number(ml),
    do: Units.to_display(ml, :volume, units)

  defp last_bottle_amount(_last, _units), do: 0.0

  defp last_bottle_contents(%Entry{data: %{"bottle_contents" => c}}) when is_binary(c), do: c
  defp last_bottle_contents(_last), do: "formula"

  defp feed_time(nil), do: nil
  defp feed_time(%Entry{started_at: at}), do: at

  defp time_of(nil), do: nil
  defp time_of(%Entry{started_at: at}), do: at

  defp feed_sub(nil, _units), do: "no feeds yet"
  defp feed_sub(%Entry{} = e, units), do: entry_title(e, units)

  defp diaper_sub(nil), do: "none yet"
  defp diaper_sub(%Entry{data: %{"kind" => k}}), do: String.capitalize(k)
  defp diaper_sub(_), do: nil

  defp sleeping?(%{running: running}), do: Enum.any?(running, &(&1.type == :sleep))

  defp sleep_value(%{running: running} = summary) do
    case Enum.find(running, &(&1.type == :sleep)) do
      %Entry{} = e -> format_duration(Entry.duration_seconds(e))
      nil -> relative_time(time_of(summary.last_sleep))
    end
  end

  defp sleep_sub(summary) do
    if sleeping?(summary), do: "asleep now", else: "since they woke up"
  end

  defp trim(f) when is_float(f) do
    if f == Float.round(f), do: trunc(f), else: Float.round(f, 1)
  end

  defp neg_all(amount), do: trunc(-amount)
end
