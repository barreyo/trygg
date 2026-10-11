defmodule TryggWeb.SleepToolkitLive do
  @moduledoc """
  The Sleep toolkit (`/c/:id/sleep/toolkit`): the tools for the 13-week stage
  and on. How they fall asleep over the weeks, bedtime planning, the night-feed
  plan (behind its gates) and the success and troubleshooting checklists.
  """
  use TryggWeb, :live_view

  alias Trygg.Families
  alias Trygg.Families.Child
  alias Trygg.Log
  alias Trygg.Reports
  alias Trygg.Sleep.Checklists
  alias TryggWeb.Loading

  @impl true
  def mount(_params, _session, socket) do
    child = socket.assigns.current_child

    if Child.tracks?(child, :sleep) do
      socket =
        socket
        |> assign(:can_write, socket.assigns.role in [:owner, :caregiver])
        |> assign(:unit_system, socket.assigns.current_scope.user.unit_system)
        |> assign(:toolkit, nil)
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

  def handle_info({:child_updated, child}, socket),
    do:
      {:noreply,
       socket |> assign(:current_child, %{child | role: socket.assigns.role}) |> refresh()}

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

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Events ----------------------------------------------------------------

  @impl true
  def handle_event("toggle_check", %{"id" => id}, socket) do
    manual = Checklists.troubleshooting_ids() ++ manual_success_ids()

    if socket.assigns.can_write and id in manual do
      child = socket.assigns.current_child

      case Families.toggle_sleep_check(
             socket.assigns.current_scope,
             child,
             id,
             Child.local_today(child)
           ) do
        {:ok, updated} -> {:noreply, socket |> assign(:current_child, updated) |> refresh()}
        {:error, _} -> {:noreply, put_flash(socket, :error, "Couldn't save that.")}
      end
    else
      {:noreply, socket}
    end
  end

  # The pediatrician's go-ahead for night weaning: recorded by a caregiver with
  # today's date, cleared again with the same button.
  def handle_event("set_clearance", %{"kind" => "night_weaning"}, socket) do
    child = socket.assigns.current_child

    if socket.assigns.can_write do
      value = if child.night_weaning_cleared_on, do: nil, else: Child.local_today(child)

      case Families.update_sleep_toolkit(socket.assigns.current_scope, child, %{
             night_weaning_cleared_on: value
           }) do
        {:ok, updated} -> {:noreply, socket |> assign(:current_child, updated) |> refresh()}
        {:error, _} -> {:noreply, put_flash(socket, :error, "Couldn't save that.")}
      end
    else
      {:noreply, socket}
    end
  end

  defp manual_success_ids do
    # Items ticked by hand: the ones `Checklists.evaluate/1` doesn't mark auto.
    child = %Child{sleep_checks: %{}, timezone: "Etc/UTC"}

    %{child: child, nights: %{nights: []}, falling_asleep: nil, habits: %{week: %{cued: 0}}}
    |> Checklists.evaluate()
    |> Map.fetch!(:success)
    |> Enum.reject(& &1.auto?)
    |> Enum.map(& &1.id)
  end

  ## Data --------------------------------------------------------------------

  defp load(socket) do
    scope = socket.assigns.current_scope
    child = socket.assigns.current_child
    Loading.run(socket, fn -> fetch(scope, child) end, &apply_data/2)
  end

  defp refresh(%{assigns: %{loaded?: false}} = socket), do: load(socket)

  defp refresh(socket),
    do: apply_data(socket, fetch(socket.assigns.current_scope, socket.assigns.current_child))

  defp fetch(scope, child) do
    summary = Log.summary(scope, child)

    %{
      toolkit:
        Reports.sleep_toolkit(scope, child, DateTime.utc_now(),
          last_feed_at: Log.last_feed_at(summary)
        )
    }
  end

  defp apply_data(socket, data), do: assign(socket, Map.to_list(data))

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
      <.sleep_subnav current={:toolkit} child={@current_child} />
      <.loadable id="toolkit-content" loaded={@loaded?} failed={@load_failed?}>
        <:skeleton><.toolkit_skeleton /></:skeleton>
        <Layouts.columns id="toolkit-columns">
          <:left>
            <.falling_asleep_panel falling_asleep={@toolkit.falling_asleep} phase={@toolkit.phase} />
            <.bedtime_panel
              plan={@toolkit.bedtime_plan}
              table={@toolkit.table}
              guide_day={@toolkit.guide_day}
              tz={@current_child.timezone}
            />
          </:left>
          <:right>
            <.night_feeds_panel
              gates={@toolkit.night_feed_gates}
              plan={@toolkit.night_feed_plan}
              unit_system={@unit_system}
              tz={@current_child.timezone}
              can_write={@can_write}
              child_id={@current_child.id}
            />
            <.night_wakes_panel summary={@toolkit.night_wakes} child_id={@current_child.id} />
            <.checklists_panel checklists={@toolkit.checklists} can_write={@can_write} />
          </:right>
        </Layouts.columns>
      </.loadable>
    </Layouts.app>
    """
  end

  defp toolkit_skeleton(assigns) do
    ~H"""
    <div
      class="animate-pulse md:grid md:grid-cols-2 md:gap-6 space-y-4 md:space-y-0"
      aria-hidden="true"
    >
      <div class="h-64 rounded-box bg-base-200"></div>
      <div class="h-64 rounded-box bg-base-200"></div>
    </div>
    """
  end
end
