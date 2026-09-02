defmodule TryggWeb.TimelineLive do
  use TryggWeb, :live_view

  alias Trygg.Accounts.Scope
  alias Trygg.Families
  alias Trygg.Families.Child
  alias Trygg.Log
  alias Trygg.Log.Entry

  @limit 200
  @filters [nil, :feeding, :diaper, :sleep]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_child={@current_child}
      title="Log"
      back={~p"/c/#{@current_child}"}
    >
      <div class="flex gap-2 overflow-x-auto pb-2 -mx-4 px-4">
        <.button
          :for={f <- filters()}
          type="button"
          variant={if @filter == f, do: "primary", else: nil}
          size="sm"
          phx-click="filter"
          phx-value-type={f && to_string(f)}
          class="shrink-0"
        >
          {filter_label(f)}
        </.button>
      </div>

      <p :if={@entries_empty?} class="opacity-60 text-sm py-10 text-center">Nothing here yet.</p>

      <div id="entries" phx-update="stream" class="divide-y divide-base-300">
        <.entry_row
          :for={{dom_id, entry} <- @streams.entries}
          id={dom_id}
          entry={entry}
          unit_system={@unit_system}
          tz={@current_child.timezone}
          show_date
          on_click={@can_write && JS.push("edit", value: %{id: entry.id})}
        />
      </div>

      <.edit_modal :if={@editing} entry={@editing} form={@edit_form} />
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Trygg.Accounts.subscribe_user(socket.assigns.current_scope.user.id)

    socket =
      socket
      |> assign(:unit_system, socket.assigns.current_scope.user.unit_system)
      |> assign(:can_write, socket.assigns.role in [:owner, :caregiver])
      |> assign(:filter, nil)
      |> assign(:editing, nil)
      |> assign(:edit_form, nil)
      |> load_entries()

    {:ok, socket}
  end

  @impl true
  def handle_info({:log, _action, _entry}, socket), do: {:noreply, load_entries(socket)}

  def handle_info({:child_updated, child}, socket) do
    {:noreply, assign(socket, :current_child, %{child | role: socket.assigns.role})}
  end

  def handle_info({:child_deleted, _child_id}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "#{socket.assigns.current_child.name} was deleted.")
     |> push_navigate(to: ~p"/")}
  end

  def handle_info({:members_changed, _child_id}, socket) do
    {:noreply, resync_membership(socket)}
  end

  def handle_info({:user_updated, user}, socket) do
    {:noreply,
     socket
     |> assign(:current_scope, %{socket.assigns.current_scope | user: user})
     |> assign(:unit_system, user.unit_system)
     |> load_entries()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp resync_membership(socket) do
    scope = socket.assigns.current_scope
    child = socket.assigns.current_child

    case Families.member_role(scope, child) do
      nil ->
        socket
        |> put_flash(:error, "You no longer have access to #{child.name}.")
        |> push_navigate(to: ~p"/")

      role ->
        child = %{child | role: role}

        socket
        |> assign(:role, role)
        |> assign(:can_write, role in [:owner, :caregiver])
        |> assign(:current_child, child)
        |> assign(:current_scope, Scope.put_child(scope, child, role))
    end
  end

  @impl true
  def handle_event("filter", %{"type" => type}, socket) do
    filter = if type in [nil, ""], do: nil, else: String.to_existing_atom(type)
    {:noreply, socket |> assign(:filter, filter) |> load_entries()}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    entry = Log.get_entry!(socket.assigns.current_scope, id)
    params = edit_params(entry, socket.assigns.current_child)
    {:noreply, assign(socket, editing: entry, edit_form: to_form(params, as: :entry))}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing: nil, edit_form: nil)}
  end

  def handle_event("save_edit", %{"entry" => params}, socket) do
    entry = socket.assigns.editing
    child = socket.assigns.current_child

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

        attrs = %{
          "type" => to_string(entry.type),
          "started_at" => started_at,
          "ended_at" => ended_at,
          "note" => params["note"],
          "data" => merge_amount(entry, params["amount"])
        }

        case Log.update_entry(socket.assigns.current_scope, entry, attrs) do
          {:ok, _entry} ->
            {:noreply,
             socket |> assign(editing: nil, edit_form: nil) |> put_flash(:info, "Updated.")}

          {:error, changeset} ->
            {:noreply, assign(socket, :edit_form, to_form(changeset, as: :entry))}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "That date and time didn't look right.")}
    end
  end

  def handle_event("delete", _params, socket) do
    {:ok, _} = Log.delete_entry(socket.assigns.current_scope, socket.assigns.editing)
    {:noreply, socket |> assign(editing: nil, edit_form: nil) |> put_flash(:info, "Deleted.")}
  end

  ## ------------------------------------------------------------------

  defp load_entries(socket) do
    entries =
      Log.list_entries(socket.assigns.current_scope, socket.assigns.current_child,
        type: socket.assigns.filter,
        limit: @limit
      )

    socket
    |> assign(:entries_empty?, entries == [])
    |> stream(:entries, entries, reset: true)
  end

  defp edit_params(%Entry{} = e, %Child{} = child) do
    %{
      "started_at" => to_local_input(child, e.started_at),
      "ended_at" => to_local_input(child, e.ended_at),
      "note" => e.note,
      "amount" => amount_display(e)
    }
  end

  defp amount_display(%Entry{data: %{"amount_ml" => ml}}) when is_number(ml), do: ml
  defp amount_display(_), do: nil

  defp merge_amount(%Entry{data: data} = e, raw) do
    case {has_amount?(e), parse_number(raw)} do
      {true, n} when is_number(n) -> Map.put(data || %{}, "amount_ml", n)
      _ -> data || %{}
    end
  end

  defp has_amount?(%Entry{type: :feeding}), do: true
  defp has_amount?(_), do: false

  defp to_local_input(_child, nil), do: nil
  defp to_local_input(%Child{} = child, %DateTime{} = dt), do: Child.to_local_input(child, dt)

  # "" / nil -> {:ok, nil}; a value -> {:ok, utc_dt} or :error
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

  defp filters, do: @filters
  defp filter_label(nil), do: "All"
  defp filter_label(:feeding), do: "Feeds"
  defp filter_label(:diaper), do: "Diapers"
  defp filter_label(:sleep), do: "Sleep"

  defp time_label(%Entry{type: :sleep}), do: "Started"
  defp time_label(_), do: "Time"

  ## Edit modal ----------------------------------------------------------

  attr :entry, Entry, required: true
  attr :form, :any, required: true

  defp edit_modal(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-end sm:items-center justify-center"
      phx-window-keydown="cancel_edit"
      phx-key="escape"
    >
      <div class="absolute inset-0 bg-black/60" phx-click="cancel_edit"></div>
      <div class="relative w-full sm:max-w-md bg-base-100 border-t border-base-300 sm:border sm:rounded-box rounded-t-2xl p-5 pb-[calc(env(safe-area-inset-bottom)+1.25rem)] max-h-[90dvh] overflow-y-auto">
        <h3 class="font-semibold text-lg mb-3">Edit this {entry_noun(@entry)}</h3>

        <.form for={@form} id="edit-entry-form" phx-submit="save_edit" class="space-y-3">
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
          <.input field={@form[:note]} type="text" label="Note" />

          <div class="flex gap-2 pt-1">
            <.button type="submit" variant="primary" class="flex-1">Save</.button>
            <.button type="button" variant="ghost" phx-click="cancel_edit">Cancel</.button>
          </div>
          <.button
            type="button"
            variant="outline"
            size="sm"
            phx-click="delete"
            data-confirm="Delete this entry?"
            class="btn-error w-full mt-2"
          >
            Delete
          </.button>
        </.form>
      </div>
    </div>
    """
  end
end
