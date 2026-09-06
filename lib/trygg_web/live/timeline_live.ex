defmodule TryggWeb.TimelineLive do
  use TryggWeb, :live_view

  alias Trygg.Accounts.Scope
  alias Trygg.Families
  alias Trygg.Log

  @limit 200
  @filters [nil, :feeding, :diaper, :sleep]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_child={@current_child}
      current_tab={:log}
      children={@children}
      child_switch_to={:log}
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
          photo_src={entry.photo_key && ~p"/c/#{@current_child}/log/#{entry.id}/photo"}
          on_click={@can_write && JS.push("edit", value: %{id: entry.id})}
        />
      </div>

      <.edit_modal
        :if={@editing}
        entry={@editing}
        form={@edit_form}
        upload={@uploads.photo}
        photo_src={@editing.photo_key && ~p"/c/#{@current_child}/log/#{@editing.id}/photo"}
      />
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
      |> allow_upload(:photo,
        accept: Log.photo_accept(),
        max_entries: 1,
        max_file_size: Log.max_photo_bytes()
      )
      |> load_entries()

    {:ok, socket}
  end

  @impl true
  def handle_info({:log, _action, _entry}, socket), do: {:noreply, load_entries(socket)}

  def handle_info({:child_updated, child}, socket) do
    {:noreply, assign(socket, :current_child, %{child | role: socket.assigns.role})}
  end

  def handle_info({:child_born, child}, socket) do
    {:noreply,
     socket
     |> assign(:current_child, %{child | role: socket.assigns.role})
     |> put_flash(:info, "#{child.name} is here! 🎉 Practice entries cleared.")
     |> load_entries()}
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
    params = entry_edit_params(entry, socket.assigns.current_child)

    {:noreply,
     socket
     |> clear_photo_upload()
     |> assign(editing: entry, edit_form: to_form(params, as: :entry))}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, socket |> clear_photo_upload() |> assign(editing: nil, edit_form: nil)}
  end

  def handle_event("validate_edit", %{"entry" => params}, socket) do
    {:noreply, assign(socket, :edit_form, to_form(params, as: :entry))}
  end

  def handle_event("cancel_photo", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :photo, ref)}
  end

  def handle_event("save_edit", %{"entry" => params}, socket) do
    params = Map.merge(params, consume_photo(socket, socket.assigns.current_child))

    case save_entry_edit(
           socket.assigns.current_scope,
           socket.assigns.editing,
           socket.assigns.current_child,
           params
         ) do
      {:ok, _entry} ->
        {:noreply, socket |> assign(editing: nil, edit_form: nil) |> put_flash(:info, "Updated.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :edit_form, to_form(changeset, as: :entry))}

      {:error, :invalid_time} ->
        {:noreply, put_flash(socket, :error, "That date and time didn't look right.")}
    end
  end

  def handle_event("delete_entry", _params, socket) do
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

  defp filters, do: @filters
  defp filter_label(nil), do: "All"
  defp filter_label(:feeding), do: "Feeds"
  defp filter_label(:diaper), do: "Diapers"
  defp filter_label(:sleep), do: "Sleep"
end
