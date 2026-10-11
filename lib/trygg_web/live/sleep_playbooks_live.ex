defmodule TryggWeb.SleepPlaybooksLive do
  @moduledoc """
  The Sleep playbooks page (`/c/:id/sleep/playbooks`): what the log says is worth
  a look, the nap conventions, planners for moving bedtime, a clock change and
  travel, and the playbooks for the usual setbacks (from
  *Precious Little Sleep*, see `Trygg.Sleep.Setbacks`). Mostly reference, so the
  only things that change are the planners' forms, which live in the page and
  aren't saved.
  """
  use TryggWeb, :live_view

  alias Trygg.Families
  alias Trygg.Families.Child
  alias Trygg.Reports
  alias Trygg.Sleep.{BedtimePlan, Setbacks}
  alias TryggWeb.Loading

  @impl true
  def mount(_params, _session, socket) do
    child = socket.assigns.current_child

    if Child.tracks?(child, :sleep) do
      socket =
        socket
        |> assign(:playbooks, nil)
        |> assign(shift_form: nil, shift_rows: [], dst_form: nil, dst_plan: nil)
        |> assign(travel_form: nil, travel_plan: nil)
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
        {:noreply, socket |> assign(:role, role) |> assign(:current_child, %{child | role: role})}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Events ----------------------------------------------------------------

  @impl true
  def handle_event("shift_change", %{"shift" => params}, socket),
    do: {:noreply, assign_shift(socket, params)}

  def handle_event("dst_change", %{"dst" => params}, socket),
    do: {:noreply, assign_dst(socket, params)}

  def handle_event("travel_change", %{"travel" => params}, socket),
    do: {:noreply, assign_travel(socket, params)}

  ## Planners ----------------------------------------------------------------

  defp assign_shift(socket, params) do
    plan =
      with from_bed when is_integer(from_bed) <- parse_time(params["from_bed"]),
           to_bed when is_integer(to_bed) <- parse_time(params["to_bed"]) do
        Setbacks.shift_plan(%{
          from_bed: from_bed,
          to_bed: to_bed,
          from_wake: parse_time(params["from_wake"]),
          to_wake: parse_time(params["to_wake"])
        })
      else
        _ -> []
      end

    assign(socket, shift_form: to_form(params, as: :shift), shift_rows: plan)
  end

  defp assign_dst(socket, params) do
    plan =
      with {:ok, direction} <- parse_direction(params["direction"]),
           {:ok, date} <- Date.from_iso8601(params["date"] || ""),
           bed when is_integer(bed) <- parse_time(params["bed"]),
           wake when is_integer(wake) <- parse_time(params["wake"]) do
        Setbacks.dst_plan(direction, date, %{bed: bed, wake: wake})
      else
        _ -> %{rows: [], tips: []}
      end

    assign(socket, dst_form: to_form(params, as: :dst), dst_plan: plan)
  end

  defp assign_travel(socket, params) do
    hours = clamp(parse_int(params["hours"]), 0, 12)
    days = clamp(parse_int(params["days"]), 1, 60)
    direction = if params["direction"] == "east", do: :east, else: :west

    assign(socket,
      travel_form: to_form(params, as: :travel),
      travel_plan: Setbacks.travel_plan(%{hours: hours, direction: direction, days: days})
    )
  end

  defp parse_direction("forward"), do: {:ok, :forward}
  defp parse_direction("back"), do: {:ok, :back}
  defp parse_direction(_), do: :error

  defp clamp(nil, lo, _hi), do: lo
  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  defp parse_int(value) do
    case Integer.parse(to_string(value)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_time(value) when is_binary(value) do
    case String.split(value, ":") do
      [h, m | _] ->
        with {h, ""} <- Integer.parse(h),
             {m, ""} <- Integer.parse(m),
             true <- h in 0..23 and m in 0..59,
             do: h * 60 + m,
             else: (_ -> nil)

      _ ->
        nil
    end
  end

  defp parse_time(_), do: nil

  defp time_value(nil, default), do: default
  defp time_value(minutes, _default), do: BedtimePlan.clock(rem(minutes, 1440))

  ## Data --------------------------------------------------------------------

  defp load(socket) do
    scope = socket.assigns.current_scope
    child = socket.assigns.current_child
    Loading.run(socket, fn -> fetch(scope, child) end, &apply_data/2)
  end

  defp refresh(%{assigns: %{loaded?: false}} = socket), do: load(socket)

  defp refresh(socket),
    do: apply_data(socket, fetch(socket.assigns.current_scope, socket.assigns.current_child))

  defp fetch(scope, child), do: %{playbooks: Reports.sleep_playbooks(scope, child)}

  # The planners start from what the log says is usual, once; after that the
  # parent's own edits stay.
  defp apply_data(socket, %{playbooks: playbooks}) do
    socket = assign(socket, :playbooks, playbooks)
    child = socket.assigns.current_child
    usual = playbooks.usual
    today = Child.local_today(child)

    socket =
      if socket.assigns.shift_form do
        socket
      else
        assign_shift(socket, %{
          "from_bed" => time_value(usual.bed, "21:00"),
          "to_bed" => "19:30",
          "from_wake" => time_value(usual.wake, "07:00"),
          "to_wake" => ""
        })
      end

    socket =
      if socket.assigns.dst_form do
        socket
      else
        {direction, date} =
          case playbooks.dst do
            %{direction: direction, date: date} -> {direction, date}
            nil -> {:forward, Date.add(today, 7)}
          end

        assign_dst(socket, %{
          "direction" => Atom.to_string(direction),
          "date" => Date.to_iso8601(date),
          "bed" => time_value(usual.bed, "19:30"),
          "wake" => time_value(usual.wake, "06:30")
        })
      end

    if socket.assigns.travel_form do
      socket
    else
      assign_travel(socket, %{"hours" => "3", "direction" => "west", "days" => "7"})
    end
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
      <.sleep_subnav current={:playbooks} child={@current_child} />
      <.loadable id="playbooks-content" loaded={@loaded?} failed={@load_failed?}>
        <:skeleton><.playbooks_skeleton /></:skeleton>
        <Layouts.columns id="playbooks-columns">
          <:left>
            <.findings_panel findings={@playbooks.findings} />
            <.naps_panel naps={@playbooks.naps} drop={@playbooks.drop} />
            <.shift_planner form={@shift_form} rows={@shift_rows} />
            <.dst_planner
              form={@dst_form}
              plan={@dst_plan}
              open={Enum.any?(@playbooks.findings, &(&1.id == :dst))}
            />
            <.travel_planner form={@travel_form} plan={@travel_plan} />
          </:left>
          <:right>
            <.playbook_cards />
            <.medical_panel />
          </:right>
        </Layouts.columns>
      </.loadable>
    </Layouts.app>
    """
  end

  defp playbooks_skeleton(assigns) do
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
