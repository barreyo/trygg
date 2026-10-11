defmodule TryggWeb.SleepPlanLive do
  @moduledoc """
  The Sleep plan page (`/c/:id/sleep/plan`): "The ABCs of Sleep"
  (`Trygg.Sleep.Abcs`), the 14-night plan for babies over 5 months.

  Before it starts: what it asks of you, the gates (5 months corrected, the
  pediatrician's go-ahead, the pre-flight list) and the night-feed setup. Once
  it's running: tonight's instructions, the night chart, progress, the
  night-weaning table and the nap training signs. The nights themselves are
  worked through in night mode (`TryggWeb.SleepNightLive`).
  """
  use TryggWeb, :live_view

  alias Trygg.Families
  alias Trygg.Families.Child
  alias Trygg.Reports
  alias Trygg.Sleep.{Abcs, BedtimePlan, NapTraining, Plans}
  alias Trygg.Units
  alias TryggWeb.Loading
  alias TryggWeb.SleepAbcsComponents

  @manual_ids Abcs.preflight_ids() ++ ["n-day-sleep", "n-battle"]

  @impl true
  def mount(_params, _session, socket) do
    child = socket.assigns.current_child

    if Child.tracks?(child, :sleep) do
      socket =
        socket
        |> assign(:can_write, socket.assigns.role in [:owner, :caregiver])
        |> assign(:unit_system, socket.assigns.current_scope.user.unit_system)
        |> assign(:training, nil)
        |> assign(:form, nil)
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
  def handle_info({:night_wake, _action, _wake}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:sleep_plan, _action, _plan}, socket), do: {:noreply, refresh(socket)}

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
    if socket.assigns.can_write and id in (@manual_ids ++ nap_manual_ids()) do
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

  def handle_event("set_clearance", %{"kind" => "sleep_training"}, socket) do
    child = socket.assigns.current_child

    if socket.assigns.can_write do
      value = if child.sleep_training_cleared_on, do: nil, else: Child.local_today(child)

      case Families.update_sleep_toolkit(socket.assigns.current_scope, child, %{
             sleep_training_cleared_on: value
           }) do
        {:ok, updated} -> {:noreply, socket |> assign(:current_child, updated) |> refresh()}
        {:error, _} -> {:noreply, put_flash(socket, :error, "Couldn't save that.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("setup_change", %{"plan" => params}, socket),
    do: {:noreply, assign(socket, :form, to_form(params, as: :plan))}

  def handle_event("start_plan", %{"plan" => params}, socket) do
    scope = socket.assigns.current_scope
    child = socket.assigns.current_child

    with true <- socket.assigns.can_write,
         attrs <- plan_attrs(params, socket.assigns.unit_system),
         {:ok, _plan} <- Plans.start(scope, child, socket.assigns.training.phase, attrs) do
      {:noreply,
       socket |> put_flash(:info, "Night 1 starts tonight. You've got this.") |> refresh()}
    else
      false ->
        {:noreply, socket}

      {:error, :not_ready} ->
        {:noreply, put_flash(socket, :error, "Finish the list first.")}

      {:error, :already_active} ->
        {:noreply, refresh(socket)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Check the feed times and amounts.")}
    end
  end

  def handle_event("finish_plan", %{"status" => status}, socket) do
    with true <- socket.assigns.can_write,
         %{plan: plan} when not is_nil(plan) <- socket.assigns.training,
         status when status in [:completed, :stopped] <- parse_status(status),
         {:ok, _} <- Plans.finish(socket.assigns.current_scope, plan, status) do
      {:noreply, refresh(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("save_note", %{"night" => night, "note" => note}, socket) do
    with true <- socket.assigns.can_write,
         %{plan: plan} when not is_nil(plan) <- socket.assigns.training,
         {n, ""} <- Integer.parse(night),
         {:ok, _} <- Plans.put_note(socket.assigns.current_scope, plan, n, note) do
      {:noreply, refresh(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  defp parse_status("completed"), do: :completed
  defp parse_status("stopped"), do: :stopped
  defp parse_status(_), do: nil

  defp nap_manual_ids, do: NapTraining.signs() |> Enum.map(&elem(&1, 0))

  # The setup form's params into plan attrs: times as minutes after midnight,
  # bottle amounts from the display unit into ml.
  defp plan_attrs(params, unit_system) do
    count = parse_int(params["count"]) || 0
    kind = if params["kind"] == "bottle", do: :bottle, else: :nursing

    feeds =
      for i <- 1..count//1,
          time = parse_time(params["time_#{i}"]),
          amount = parse_amount(params["amount_#{i}"], kind, unit_system) do
        {time, amount}
      end

    if count == 0 or length(feeds) != count do
      if count == 0, do: %{}, else: %{feed_kind: kind, feed_times: [0], feed_amounts: []}
    else
      %{
        feed_kind: kind,
        feed_times: Enum.map(feeds, &elem(&1, 0)),
        feed_amounts: Enum.map(feeds, &elem(&1, 1))
      }
    end
  end

  defp parse_time(value) when is_binary(value) do
    case String.split(value, ":") do
      [h, m | _] ->
        with {h, ""} <- Integer.parse(h),
             {m, ""} <- Integer.parse(m),
             do: h * 60 + m,
             else: (_ -> nil)

      _ ->
        nil
    end
  end

  defp parse_time(_), do: nil

  defp parse_amount(value, kind, unit_system) do
    case Float.parse(to_string(value)) do
      {n, _} when n > 0 ->
        if kind == :bottle,
          do: round(Units.from_display(n, :volume, unit_system)),
          else: round(n)

      _ ->
        nil
    end
  end

  defp parse_int(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> n
      _ -> nil
    end
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

  defp fetch(scope, child), do: %{training: Reports.sleep_training(scope, child)}

  defp apply_data(socket, %{training: training}) do
    socket = assign(socket, :training, training)
    # Keep what's been typed into the setup form; start it from the suggestion.
    if socket.assigns.form,
      do: socket,
      else: assign(socket, :form, initial_form(training, socket.assigns.unit_system))
  end

  defp initial_form(%{setup: nil}, _system),
    do: to_form(%{"count" => "0", "kind" => "bottle"}, as: :plan)

  defp initial_form(%{setup: %{kind: kind, feeds: feeds}}, system) do
    base = %{"count" => to_string(length(feeds)), "kind" => to_string(kind)}

    params =
      feeds
      |> Enum.with_index(1)
      |> Enum.reduce(base, fn {{time, amount}, i}, acc ->
        amount_text =
          if kind == :bottle,
            do: amount |> Units.to_display(:volume, system) |> Float.round(1) |> trim(),
            else: to_string(amount)

        acc
        |> Map.put("time_#{i}", BedtimePlan.clock(time))
        |> Map.put("amount_#{i}", amount_text)
      end)

    to_form(params, as: :plan)
  end

  defp trim(n), do: if(n == trunc(n), do: Integer.to_string(trunc(n)), else: to_string(n))

  ## Render ------------------------------------------------------------------

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
      back={~p"/c/#{@current_child}/sleep"}
      wide
    >
      <.sleep_subnav current={:plan} child={@current_child} />

      <.loadable id="plan-content" loaded={@loaded?} failed={@load_failed?}>
        <:skeleton>
          <div class="h-64 animate-pulse rounded-box bg-base-200"></div>
        </:skeleton>

        <%= if @training.plan do %>
          <Layouts.columns id="plan-columns">
            <:left>
              <SleepAbcsComponents.tonight_panel
                tonight={@training.tonight}
                plan={@training.plan}
                table={@training.table}
                unit_system={@unit_system}
                can_write={@can_write}
                child_id={@current_child.id}
              />
              <SleepAbcsComponents.night_chart_panel
                nights={@training.plan_nights}
                tz={@current_child.timezone}
                tonight={@training.tonight}
                can_write={@can_write}
              />
              <SleepAbcsComponents.progress_panel
                progress={@training.progress}
                nights={@training.plan_nights}
              />
            </:left>
            <:right>
              <SleepAbcsComponents.weaning_table_panel
                table={@training.weaning_table}
                unit_system={@unit_system}
              />
              <SleepAbcsComponents.plan_controls
                plan={@training.plan}
                tonight={@training.tonight}
                can_write={@can_write}
              />
              <SleepAbcsComponents.nap_panel
                readiness={@training.nap_readiness}
                table={@training.table}
                night={@training.tonight.night}
                can_write={@can_write}
              />
            </:right>
          </Layouts.columns>
        <% else %>
          <Layouts.columns id="plan-columns">
            <:left>
              <SleepAbcsComponents.abcs_intro />
              <SleepAbcsComponents.gates_panel
                eligibility={@training.eligibility}
                can_write={@can_write}
              />
            </:left>
            <:right>
              <SleepAbcsComponents.setup_form
                :if={match?({:ok, _}, @training.eligibility.age) and @can_write}
                form={@form}
                count={parse_int(@form.params["count"]) || 0}
                kind={@form.params["kind"] || "bottle"}
                unit_system={@unit_system}
                ready?={@training.eligibility.ready?}
              />
              <SleepAbcsComponents.nap_panel
                readiness={@training.nap_readiness}
                table={@training.table}
                can_write={@can_write}
              />
            </:right>
          </Layouts.columns>
        <% end %>
      </.loadable>
    </Layouts.app>
    """
  end
end
