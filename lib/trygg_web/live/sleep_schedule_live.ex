defmodule TryggWeb.SleepScheduleLive do
  @moduledoc """
  The sleep schedule (`/c/:id/sleep/schedule`): the day the family follows,
  which is the guide for their child's age with their own wake-up, bedtime and
  nap choices laid on top. Before 13 weeks it's a soft rhythm (wake-up and
  evening anchors); from 13 weeks it lists the naps and bedtime.
  """
  use TryggWeb, :live_view

  alias Trygg.Families
  alias Trygg.Families.Child
  alias Trygg.Reports
  alias Trygg.Sleep.DaySchedules
  alias TryggWeb.Loading

  @impl true
  def mount(_params, _session, socket) do
    child = socket.assigns.current_child

    if Child.tracks?(child, :sleep) do
      socket =
        socket
        |> assign(:can_write, socket.assigns.role in [:owner, :caregiver])
        |> assign(data: nil, form: nil)
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
  def handle_info({:day_schedule, _action, _schedule}, socket), do: {:noreply, refresh(socket)}

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

  # Typing in the form keeps what's typed, and a change of nap count adds or
  # drops rows, without saving anything.
  @impl true
  def handle_event("validate", %{"schedule" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :schedule))}
  end

  def handle_event("save", %{"schedule" => params}, socket) do
    if socket.assigns.can_write do
      scope = socket.assigns.current_scope
      child = socket.assigns.current_child

      case DaySchedules.save(scope, child, DaySchedules.parse_params(params)) do
        {:ok, _} ->
          {:noreply, socket |> put_flash(:info, "Schedule saved.") |> refresh(reset_form: true)}

        {:error, changeset} ->
          {:noreply, put_flash(socket, :error, error_message(changeset))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("reset", _params, socket) do
    if socket.assigns.can_write do
      {:ok, _} = DaySchedules.clear(socket.assigns.current_scope, socket.assigns.current_child)
      {:noreply, socket |> put_flash(:info, "Back to the guide.") |> refresh(reset_form: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("keep_guide", _params, socket) do
    if socket.assigns.can_write do
      {:ok, _} =
        DaySchedules.acknowledge(socket.assigns.current_scope, socket.assigns.current_child)

      {:noreply, refresh(socket)}
    else
      {:noreply, socket}
    end
  end

  # Suggestions are looked up afresh by id, so what's applied is what the log
  # says now, never what a stale page or a crafted event claims.
  def handle_event("accept", %{"id" => id}, socket) do
    with true <- socket.assigns.can_write,
         %{} = suggestion <- find_suggestion(socket, id) do
      case DaySchedules.accept(
             socket.assigns.current_scope,
             socket.assigns.current_child,
             suggestion
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Applied: #{suggestion.title}.")
           |> refresh(reset_form: true)}

        {:error, changeset} ->
          {:noreply, put_flash(socket, :error, error_message(changeset))}
      end
    else
      _ -> {:noreply, refresh(socket)}
    end
  end

  def handle_event("dismiss", %{"id" => id}, socket) do
    with true <- socket.assigns.can_write,
         %{} = suggestion <- find_suggestion(socket, id),
         {:ok, _} <-
           DaySchedules.dismiss(
             socket.assigns.current_scope,
             socket.assigns.current_child,
             suggestion.key
           ) do
      {:noreply, refresh(socket)}
    else
      _ -> {:noreply, refresh(socket)}
    end
  end

  defp find_suggestion(socket, id) do
    %{data: data} = fetch(socket.assigns.current_scope, socket.assigns.current_child)
    Enum.find(data.coach.suggestions, &(Atom.to_string(&1.id) == id))
  end

  defp error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} ->
      "#{field |> to_string() |> String.replace("_", " ")} #{Enum.join(msgs, ", ")}"
    end)
    |> then(&"Couldn't save: #{&1}.")
  end

  ## Data --------------------------------------------------------------------

  defp load(socket) do
    scope = socket.assigns.current_scope
    child = socket.assigns.current_child
    Loading.run(socket, fn -> fetch(scope, child) end, &apply_data/2)
  end

  defp refresh(socket, opts \\ [])
  defp refresh(%{assigns: %{loaded?: false}} = socket, _opts), do: load(socket)

  defp refresh(socket, opts) do
    data = fetch(socket.assigns.current_scope, socket.assigns.current_child)

    # A change someone else made refreshes the picture, but never overwrites
    # what's half-typed here.
    if opts[:reset_form] || is_nil(socket.assigns.form),
      do: apply_data(socket, data),
      else: assign(socket, :data, data.data)
  end

  defp fetch(scope, child) do
    %{data: Reports.sleep_schedule(scope, child, DateTime.utc_now())}
  end

  defp apply_data(socket, %{data: data}) do
    socket
    |> assign(:data, data)
    |> assign(:form, to_form(form_params(data.schedule), as: :schedule))
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
      title="Sleep schedule"
      back={~p"/c/#{@current_child}/sleep"}
      wide
    >
      <.sleep_subnav current={:today} child={@current_child} />
      <.loadable id="schedule-content" loaded={@loaded?} failed={@load_failed?}>
        <:skeleton><.schedule_skeleton /></:skeleton>
        <%= if @data.effective do %>
          <Layouts.columns id="schedule-columns">
            <:left>
              <.schedule_day_panel
                eff={@data.effective}
                tz={@current_child.timezone}
                can_write={@can_write}
              />
              <.schedule_suggestions_panel
                coach={@data.coach}
                history={(@data.schedule && @data.schedule.history) || []}
                can_write={@can_write}
              />
            </:left>
            <:right>
              <.schedule_form_panel form={@form} eff={@data.effective} can_write={@can_write} />
            </:right>
          </Layouts.columns>
        <% else %>
          <p id="schedule-needs-birth-date" class="text-sm opacity-80">
            Add {@current_child.name}'s birth date and their day shows up here.
          </p>
        <% end %>
      </.loadable>
    </Layouts.app>
    """
  end

  defp schedule_skeleton(assigns) do
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
