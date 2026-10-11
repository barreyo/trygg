defmodule TryggWeb.SleepNightLive do
  @moduledoc """
  Night mode (`/c/:id/sleep/night`): a dark, glanceable screen to work through a
  night waking one step at a time (C.R.I.E.S. for a newborn, S.I.T. B.A.C.K. from
  13 weeks), with a countdown for each step.

  The step and when it began live in the database (`Trygg.Sleep.NightWakes`) and
  every change is broadcast, so the other caregiver's phone shows the same step
  and the same countdown and can take over mid-sequence.
  """
  use TryggWeb, :live_view

  alias Trygg.Families
  alias Trygg.Families.Child
  alias Trygg.Log
  alias Trygg.Reports
  alias Trygg.Sleep.{Methods, NightWake, NightWakes, Phase, Plans}
  alias TryggWeb.SleepAbcsComponents
  alias TryggWeb.Loading

  @impl true
  def mount(_params, _session, socket) do
    child = socket.assigns.current_child

    if Child.tracks?(child, :sleep) do
      scope = socket.assigns.current_scope

      socket =
        socket
        |> assign(:can_write, socket.assigns.role in [:owner, :caregiver])
        |> assign(active: NightWakes.active(scope, child), recent: [], hint: nil)
        |> assign(:last_wake, nil)
        |> assign_plan(scope, child)
        |> Loading.init()
        |> load()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(
         :info,
         "Sleep isn't tracked for #{child.name}. Turn it on from Today → Customize."
       )
       |> push_navigate(to: ~p"/c/#{child}")}
    end
  end

  # While a sleep-training plan is running, night mode is the plan's check-ins;
  # otherwise the method for the child's age.
  defp assign_plan(socket, scope, child) do
    plan = Plans.active(scope, child)
    tonight = plan && Plans.tonight(plan, child, DateTime.utc_now())

    socket
    |> assign(:plan, plan)
    |> assign(:tonight, tonight)
    |> assign(:bedtime_at, bedtime_at(scope, plan, child, tonight))
    |> assign(:method, if(plan, do: :abcs, else: Methods.for_phase(phase_id(child))))
  end

  # When they were put down tonight, from the plan's bedtime waking.
  defp bedtime_at(_scope, nil, _child, _tonight), do: nil
  defp bedtime_at(_scope, _plan, _child, %{night: night}) when night < 1, do: nil

  defp bedtime_at(scope, plan, child, %{night: night}) do
    scope
    |> NightWakes.for_plan(plan)
    |> Enum.find(
      &(&1.kind == :bedtime and Plans.night_number(plan, child, &1.started_at) == night)
    )
    |> then(&(&1 && &1.started_at))
  end

  defp phase_id(child) do
    case Phase.for_child(child) do
      %{id: id} -> id
      nil -> :newborn
    end
  end

  @impl true
  def handle_async(:load, result, socket),
    do: {:noreply, Loading.done(socket, result, &apply_data/2)}

  @impl true
  def handle_info({:night_wake, :finished, wake}, socket) do
    {:noreply, socket |> assign(active: nil, last_wake: wake) |> refresh_recent()}
  end

  def handle_info({:night_wake, _action, wake}, socket),
    do: {:noreply, assign(socket, :active, wake)}

  def handle_info({:log, _action, _entry}, socket), do: {:noreply, refresh(socket)}

  def handle_info({:sleep_plan, _action, _plan}, socket) do
    {:noreply, assign_plan(socket, socket.assigns.current_scope, socket.assigns.current_child)}
  end

  def handle_info({:child_updated, child}, socket),
    do: {:noreply, assign(socket, :current_child, %{child | role: socket.assigns.role})}

  def handle_info({:child_deleted, _child_id}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "#{socket.assigns.current_child.name} was deleted.")
     |> push_navigate(to: ~p"/")}
  end

  def handle_info({:members_changed, _child_id}, socket) do
    scope = socket.assigns.current_scope
    child = socket.assigns.current_child

    case Families.member_role(scope, child) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "You no longer have access to #{child.name}.")
         |> push_navigate(to: ~p"/")}

      role ->
        {:noreply,
         socket
         |> assign(:role, role)
         |> assign(:can_write, role in [:owner, :caregiver])
         |> assign(:current_child, %{child | role: role})}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Events ----------------------------------------------------------------

  @impl true
  def handle_event("start", _params, socket) do
    if socket.assigns.can_write do
      {:ok, wake} =
        NightWakes.start(
          socket.assigns.current_scope,
          socket.assigns.current_child,
          socket.assigns.method
        )

      {:noreply, assign(socket, active: wake, last_wake: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("start_abcs", %{"kind" => kind}, socket) do
    kind = if kind == "bedtime", do: :bedtime, else: :waking

    if socket.assigns.can_write and socket.assigns.method == :abcs do
      plan = socket.assigns.plan

      {:ok, wake} =
        NightWakes.start(socket.assigns.current_scope, socket.assigns.current_child, :abcs,
          kind: kind,
          plan_id: plan && plan.id
        )

      {:noreply,
       socket
       |> assign(active: wake, last_wake: nil)
       |> assign_plan(socket.assigns.current_scope, socket.assigns.current_child)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("record", %{"kind" => kind, "seen" => seen}, socket) do
    with true <- socket.assigns.can_write,
         %NightWake{method: :abcs} = wake <- socket.assigns.active,
         {seen, ""} <- Integer.parse(seen),
         {:ok, updated} <- NightWakes.record(socket.assigns.current_scope, wake, kind, seen) do
      {:noreply, assign(socket, :active, updated)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("asleep", %{"seen" => seen}, socket) do
    with true <- socket.assigns.can_write,
         %NightWake{method: :abcs} = wake <- socket.assigns.active,
         {seen, ""} <- Integer.parse(seen),
         {:ok, finished} <- NightWakes.asleep(socket.assigns.current_scope, wake, seen) do
      {:noreply,
       socket
       |> assign(active: nil, last_wake: finished)
       |> assign_plan(socket.assigns.current_scope, socket.assigns.current_child)
       |> refresh_recent()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("next", %{"step" => step}, socket),
    do: {:noreply, step_event(socket, step, &NightWakes.advance/3)}

  def handle_event("restart", %{"step" => step}, socket),
    do: {:noreply, step_event(socket, step, &NightWakes.restart/3)}

  def handle_event("finish", %{"outcome" => outcome}, socket) do
    with true <- socket.assigns.can_write,
         %NightWake{} = wake <- socket.assigns.active,
         outcome when outcome in [:settled, :fed, :stopped] <- parse_outcome(outcome),
         {:ok, finished} <- NightWakes.finish(socket.assigns.current_scope, wake, outcome) do
      {:noreply, socket |> assign(active: nil, last_wake: finished) |> refresh_recent()}
    else
      _ -> {:noreply, socket}
    end
  end

  defp step_event(socket, step, fun) do
    with true <- socket.assigns.can_write,
         %NightWake{} = wake <- socket.assigns.active,
         {step, ""} <- Integer.parse(step),
         {:ok, moved} <- fun.(socket.assigns.current_scope, wake, step) do
      assign(socket, :active, moved)
    else
      _ -> socket
    end
  end

  defp parse_outcome("settled"), do: :settled
  defp parse_outcome("fed"), do: :fed
  defp parse_outcome("stopped"), do: :stopped
  defp parse_outcome(_), do: nil

  ## Data --------------------------------------------------------------------

  defp load(socket) do
    scope = socket.assigns.current_scope
    child = socket.assigns.current_child
    Loading.run(socket, fn -> fetch(scope, child) end, &apply_data/2)
  end

  defp refresh(%{assigns: %{loaded?: false}} = socket), do: load(socket)

  defp refresh(socket),
    do: apply_data(socket, fetch(socket.assigns.current_scope, socket.assigns.current_child))

  defp refresh_recent(socket) do
    assign(
      socket,
      :recent,
      NightWakes.recent(socket.assigns.current_scope, socket.assigns.current_child)
    )
  end

  defp fetch(scope, child) do
    summary = Log.summary(scope, child)
    last_feed_at = Log.last_feed_at(summary)
    toolkit = Reports.sleep_toolkit(scope, child, DateTime.utc_now(), last_feed_at: last_feed_at)

    %{
      active: NightWakes.active(scope, child),
      recent: NightWakes.recent(scope, child),
      hint: %{
        gates: toolkit.night_feed_gates,
        earliest: toolkit.night_feed_plan.earliest,
        last_feed_at: last_feed_at
      }
    }
  end

  defp apply_data(socket, data), do: assign(socket, Map.to_list(data))

  ## Render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        method_info: Methods.get(assigns.method),
        step_info: assigns.active && Methods.step(assigns.active.method, assigns.active.step),
        summary: NightWakes.summarize(assigns.recent)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_child={@current_child}
      current_tab={:sleep}
      children={@children}
      child_switch_to={:sleep}
      title="Sleep"
      back={~p"/c/#{@current_child}/sleep"}
      wide
    >
      <.sleep_subnav current={:night} child={@current_child} />

      <section
        id="night-mode"
        class="rounded-[var(--radius-card)] bg-black p-5 text-[#d8b9a4] ring-1 ring-[#3a2a22]"
      >
        <.loadable id="night-content" loaded={@loaded?} failed={@load_failed?}>
          <:skeleton>
            <div class="h-64 animate-pulse rounded-box bg-[#140d0a]"></div>
          </:skeleton>

          <%= cond do %>
            <% @active && @active.method == :abcs -> %>
              <SleepAbcsComponents.abcs_screen
                wake={@active}
                tonight={@tonight}
                bedtime_at={@bedtime_at}
                can_write={@can_write}
                now={DateTime.utc_now()}
                tz={@current_child.timezone}
              />
            <% @active -> %>
              <.step_screen
                wake={@active}
                step={@step_info}
                method={Methods.get(@active.method)}
                can_write={@can_write}
                hint={@hint}
                now={DateTime.utc_now()}
                tz={@current_child.timezone}
              />
            <% @method == :abcs -> %>
              <SleepAbcsComponents.abcs_idle
                plan={@plan}
                tonight={@tonight}
                can_write={@can_write}
                unit_system={@current_scope.user.unit_system}
                tz={@current_child.timezone}
                last_wake={@last_wake}
              />
            <% true -> %>
              <.idle_screen
                method={@method_info}
                can_write={@can_write}
                last_wake={@last_wake}
                summary={@summary}
                child={@current_child}
              />
          <% end %>
        </.loadable>
      </section>
    </Layouts.app>
    """
  end

  attr :method, :map, required: true
  attr :can_write, :boolean, required: true
  attr :last_wake, :any, default: nil
  attr :summary, :map, required: true
  attr :child, :map, required: true

  defp idle_screen(assigns) do
    ~H"""
    <div id="night-idle" class="space-y-4">
      <p :if={@last_wake} id="night-last" class="rounded-box bg-[#1b110c] p-3 text-sm">
        {last_line(@last_wake)}
      </p>

      <h2 class="text-xl font-semibold">{@method.label}</h2>
      <p class="text-sm opacity-80">{method_blurb(@method.id)}</p>

      <ol id="night-steps-preview" class="flex flex-wrap gap-2" aria-label="Steps">
        <li
          :for={step <- @method.steps}
          class="grid size-9 place-items-center rounded-full border border-[#5a3f31] text-sm font-semibold"
        >
          {step.letter}
        </li>
      </ol>

      <button
        :if={@can_write}
        id="night-start"
        type="button"
        phx-click="start"
        class="w-full rounded-box bg-[#7a3b24] py-6 text-2xl font-semibold text-[#ffe9dc] active:bg-[#8f452b]"
      >
        Start {@method.label}
      </button>
      <p :if={!@can_write} class="text-sm opacity-70">
        You can watch a waking here, but only a caregiver can start one.
      </p>

      <div :if={@summary.count > 0} id="night-recent" class="border-t border-[#3a2a22] pt-3 text-sm">
        <p class="font-medium">Last 7 days</p>
        <p class="opacity-80">{summary_line(@summary)}</p>
      </div>
    </div>
    """
  end

  attr :wake, :map, required: true
  attr :step, :map, required: true
  attr :method, :map, required: true
  attr :can_write, :boolean, required: true
  attr :hint, :map, default: nil
  attr :now, :any, required: true
  attr :tz, :string, required: true

  defp step_screen(assigns) do
    assigns =
      assign(assigns,
        timed?: is_integer(assigns.step.seconds),
        ends_at:
          is_integer(assigns.step.seconds) &&
            DateTime.to_unix(assigns.wake.step_started_at) * 1000 + assigns.step.seconds * 1000,
        last_step?: assigns.wake.step + 1 >= length(assigns.method.steps)
      )

    ~H"""
    <div id="night-step" data-step={@wake.step} class="space-y-5">
      <div class="flex items-center justify-between gap-3 text-sm">
        <p id="night-method" class="font-medium">{@method.label}</p>
        <p id="night-started-by" class="opacity-70">
          Started {clock(@wake.started_at, @tz)}{started_by(@wake)}
        </p>
      </div>

      <ol id="night-progress" class="flex gap-1.5" aria-label="Progress">
        <li
          :for={{step, i} <- Enum.with_index(@method.steps)}
          aria-current={i == @wake.step && "step"}
          class={[
            "grid size-8 place-items-center rounded-full border text-sm font-semibold",
            i == @wake.step && "border-[#d8b9a4] bg-[#7a3b24] text-[#ffe9dc]",
            i < @wake.step && "border-[#5a3f31] opacity-60",
            i > @wake.step && "border-[#3a2a22] opacity-50"
          ]}
        >
          {step.letter}
        </li>
      </ol>

      <div class="text-center">
        <p id="night-step-letter" class="text-8xl font-bold leading-none text-[#ffd9c2]">
          {@step.letter}
        </p>
        <h2 id="night-step-name" class="mt-2 text-2xl font-semibold">{@step.name}</h2>
        <p id="night-step-detail" class="mx-auto mt-2 max-w-md text-base opacity-90">
          {@step.detail}
        </p>
      </div>

      <div
        :if={@timed?}
        id="night-countdown"
        phx-hook="NightTimer"
        data-ends-at={@ends_at}
        data-elapsed="false"
        class="group text-center"
      >
        <p
          data-night-time
          class="text-6xl font-bold tabular-nums group-data-[elapsed=true]:text-[#ffb27a]"
        >
          {format_seconds(@step.seconds)}
        </p>
        <p class="mt-1 text-sm opacity-70 group-data-[elapsed=true]:text-[#ffb27a]">
          <span class="group-data-[elapsed=true]:hidden">
            {step_limit(@step)}
          </span>
          <span class="hidden group-data-[elapsed=true]:inline">
            Time's up. Still fussing? Move to the next step.
          </span>
        </p>
      </div>

      <p :if={@last_step?} id="night-feed-hint" class="rounded-box bg-[#1b110c] p-3 text-sm">
        {feed_hint(@hint, @now, @tz)}
      </p>

      <div :if={@can_write} class="grid gap-3">
        <%= if @last_step? and @method.id == :sit_back do %>
          <button
            id="night-fed"
            type="button"
            phx-click="finish"
            phx-value-outcome="fed"
            class="rounded-box bg-[#7a3b24] py-5 text-xl font-semibold text-[#ffe9dc]"
          >
            Fed them
          </button>
          <button
            id="night-restart"
            type="button"
            phx-click="restart"
            phx-value-step={@wake.step}
            class="rounded-box border border-[#5a3f31] py-4 text-lg"
          >
            Not due: start over
          </button>
        <% else %>
          <button
            :if={!@last_step?}
            id="night-next"
            type="button"
            phx-click="next"
            phx-value-step={@wake.step}
            class="rounded-box border border-[#5a3f31] py-5 text-xl font-semibold"
          >
            Next step
          </button>
        <% end %>

        <button
          id="night-settled"
          type="button"
          phx-click="finish"
          phx-value-outcome="settled"
          class="rounded-box bg-[#274b36] py-5 text-xl font-semibold text-[#d6f5e3]"
        >
          They settled
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

  ## Copy --------------------------------------------------------------------

  defp method_blurb(:cries),
    do:
      "Five things to try, in order, for a crying newborn: contain, roll onto the side (while you hold them), introduce movement, external sound, suck."

  defp method_blurb(:sit_back),
    do:
      "Helps them settle with the least help they need. Give each step its time before moving on; the guide suggests using it for one waking a night and comforting however helps for the rest."

  defp started_by(%{started_by: %{first_name: name}}) when is_binary(name) and name != "",
    do: " by #{name}"

  defp started_by(_wake), do: ""

  defp step_limit(%{seconds: s, max_seconds: max}) when is_integer(max) and max > s,
    do: "Up to #{div(max, 60)} minutes if they're only fussing."

  defp step_limit(_step), do: "Give it the full time."

  defp format_seconds(seconds),
    do: "#{div(seconds, 60)}:#{String.pad_leading("#{rem(seconds, 60)}", 2, "0")}"

  defp last_line(%{outcome: :settled, settled_step: step, method: method}),
    do: "Settled at step #{step + 1} (#{step_letter(method, step)}). Sleep well."

  defp last_line(%{outcome: :fed}), do: "Fed. Remember to log the feed."
  defp last_line(_wake), do: "Stopped."

  defp step_letter(method, step) do
    case Methods.step(method, step) do
      %{letter: letter} -> letter
      nil -> "?"
    end
  end

  defp summary_line(%{count: count, settled: settled, fed: fed, settled_at: at}) do
    base =
      "#{count} #{if count == 1, do: "waking", else: "wakings"}: #{settled} settled, #{fed} ended in a feed."

    case Enum.sort(at) do
      [] ->
        base

      list ->
        base <>
          " Settled at step " <>
          Enum.map_join(list, ", ", fn {step, n} -> "#{step + 1} (#{n}×)" end) <> "."
    end
  end

  # What the feed plan says about offering one now.
  defp feed_hint(%{gates: %{ready?: true}, earliest: %{state: :wait} = earliest}, _now, tz),
    do:
      "The plan says hold off a feed until #{clock(earliest.at, tz)}. Keep going with the steps until then."

  defp feed_hint(%{gates: %{ready?: true}, earliest: %{state: :open}}, _now, _tz),
    do: "It's been long enough since the last feed that one is fine now."

  defp feed_hint(%{last_feed_at: %DateTime{} = at}, now, _tz),
    do:
      "Last fed #{format_duration(DateTime.diff(now, at, :second))} ago. Feed if they're hungry."

  defp feed_hint(_hint, _now, _tz), do: "Feed if they're hungry."
end
