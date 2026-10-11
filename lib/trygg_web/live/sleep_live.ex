defmodule TryggWeb.SleepLive do
  @moduledoc """
  The Sleep tab: sleep coaching for the child's age, kept off the at-a-glance
  Today screen. Shows the phase of the journey, a "right now" panel for noting
  sleepy cues as a sleep starts, this week's habits, and reference content
  (C.R.I.E.S., the cue guide, a newborn rhythm and the roadmap).
  """
  use TryggWeb, :live_view

  alias Trygg.Families
  alias Trygg.Families.Child
  alias Trygg.Log
  alias Trygg.Log.Entry
  alias Trygg.Reports
  alias Trygg.Sleep.{Cue, Phase}
  alias TryggWeb.Loading

  # A cue tapped before a sleep starts is dropped if the sleep doesn't follow
  # within this long, so a stale one never labels a later sleep.
  @cue_ttl_seconds 30 * 60

  @impl true
  def mount(_params, _session, socket) do
    child = socket.assigns.current_child

    if Child.tracks?(child, :sleep) do
      if connected?(socket), do: Process.send_after(self(), :tick, 60_000)

      socket =
        socket
        |> assign(:can_write, socket.assigns.role in [:owner, :caregiver])
        |> assign(summary: nil, habits: nil, phase: nil, timeline: [], plan: nil, insights: [])
        |> assign(nights: nil)
        |> assign(pending_cue: nil, pending_cue_at: nil)
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

  @impl true
  def handle_async(:load, result, socket),
    do: {:noreply, Loading.done(socket, result, &apply_data/2)}

  @impl true
  def handle_info({:log, _action, _entry}, socket), do: {:noreply, refresh(socket)}

  def handle_info({:child_updated, child}, socket) do
    {:noreply,
     socket |> assign(:current_child, %{child | role: socket.assigns.role}) |> refresh()}
  end

  def handle_info({:child_born, child}, socket) do
    {:noreply,
     socket
     |> assign(:current_child, %{child | role: socket.assigns.role})
     |> put_flash(:info, "#{child.name} is here! 🎉 Practice entries cleared.")
     |> refresh()}
  end

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

  # The plan is built from "now" (wake windows, the open nap window), so it's
  # recomputed every minute as well as on every log change.
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 60_000)
    {:noreply, socket |> expire_pending_cue() |> refresh()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Events ----------------------------------------------------------------

  @impl true
  def handle_event("start_sleep", _params, socket) do
    attrs =
      case socket.assigns.pending_cue do
        nil -> %{}
        cue -> %{"data" => %{"cue" => cue}}
      end

    if socket.assigns.can_write do
      case Log.start_timer(
             socket.assigns.current_scope,
             socket.assigns.current_child,
             :sleep,
             attrs
           ) do
        {:ok, _} ->
          {:noreply, socket |> assign(pending_cue: nil, pending_cue_at: nil) |> refresh()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Couldn't start the sleep.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("stop_sleep", _params, socket) do
    with true <- socket.assigns.can_write,
         %Entry{} = nap <- Log.running(socket.assigns.summary, :sleep),
         {:ok, _} <- Log.stop_timer(socket.assigns.current_scope, nap) do
      {:noreply, refresh(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  # While awake a tapped cue is remembered for the sleep about to start; during
  # a sleep it's saved on that sleep. Tapping the one that's set clears it.
  def handle_event("set_cue", %{"cue" => cue}, socket) do
    if socket.assigns.can_write and Cue.valid?(cue) do
      {:noreply, set_cue(socket, Log.running(socket.assigns.summary, :sleep), cue)}
    else
      {:noreply, socket}
    end
  end

  defp set_cue(socket, nil, cue) do
    if socket.assigns.pending_cue == cue,
      do: assign(socket, pending_cue: nil, pending_cue_at: nil),
      else: assign(socket, pending_cue: cue, pending_cue_at: System.system_time(:second))
  end

  defp set_cue(socket, %Entry{} = nap, cue) do
    new = if nap.data["cue"] == cue, do: nil, else: cue

    case Log.set_sleep_cue(socket.assigns.current_scope, nap, new) do
      {:ok, _} -> refresh(socket)
      {:error, _} -> put_flash(socket, :error, "Couldn't save that.")
    end
  end

  defp expire_pending_cue(%{assigns: %{pending_cue_at: at}} = socket) when is_integer(at) do
    if System.system_time(:second) - at > @cue_ttl_seconds,
      do: assign(socket, pending_cue: nil, pending_cue_at: nil),
      else: socket
  end

  defp expire_pending_cue(socket), do: socket

  ## Data --------------------------------------------------------------------

  defp load(socket) do
    scope = socket.assigns.current_scope
    child = socket.assigns.current_child
    Loading.run(socket, fn -> fetch(scope, child) end, &apply_data/2)
  end

  defp refresh(%{assigns: %{loaded?: false}} = socket), do: load(socket)

  defp refresh(socket) do
    apply_data(socket, fetch(socket.assigns.current_scope, socket.assigns.current_child))
  end

  defp fetch(scope, child) do
    summary = Log.summary(scope, child)

    %{plan: plan, insights: insights, habits: habits, phase: phase, nights: nights} =
      Reports.sleep_plan(scope, child, DateTime.utc_now(),
        last_feed_at: Log.last_feed_at(summary)
      )

    %{
      summary: summary,
      plan: plan,
      insights: insights,
      habits: habits,
      nights: nights,
      phase: phase,
      timeline: Phase.timeline(child)
    }
  end

  defp apply_data(socket, data) do
    assign(socket, Map.to_list(data))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_child={@current_child}
      current_tab={:sleep}
      children={@children}
      child_switch_to={:sleep}
      title="Sleep"
      back={~p"/c/#{@current_child}"}
      wide
    >
      <.loadable id="sleep-content" loaded={@loaded?} failed={@load_failed?}>
        <:skeleton><.sleep_skeleton /></:skeleton>
        <.phase_hero phase={@phase} timeline={@timeline} child_name={@current_child.name} />

        <Layouts.columns id="sleep-columns">
          <:left>
            <.right_now
              running={Log.running(@summary, :sleep)}
              last={@summary.last_sleep}
              pending_cue={@pending_cue}
              can_write={@can_write}
              tz={@current_child.timezone}
            />
            <.schedule_panel plan={@plan} tz={@current_child.timezone} />
            <.insights_panel insights={@insights} />
          </:left>
          <:right>
            <.overnight_panel nights={@nights} tz={@current_child.timezone} />
            <.habits_panel habits={@habits} />
            <.cries_panel :if={@phase && @phase.id == :newborn} />
            <.cue_guide />
            <.rhythm_reference :if={@phase && @phase.id == :newborn} />
            <.roadmap :if={@timeline != []} timeline={@timeline} />
          </:right>
        </Layouts.columns>
      </.loadable>
    </Layouts.app>
    """
  end

  defp sleep_skeleton(assigns) do
    ~H"""
    <div class="animate-pulse space-y-4" aria-hidden="true">
      <div class="h-40 rounded-box bg-base-200"></div>
      <div class="md:grid md:grid-cols-2 md:gap-6 space-y-4 md:space-y-0">
        <div class="h-56 rounded-box bg-base-200"></div>
        <div class="h-56 rounded-box bg-base-200"></div>
      </div>
    </div>
    """
  end
end
