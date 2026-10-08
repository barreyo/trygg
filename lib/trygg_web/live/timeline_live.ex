defmodule TryggWeb.TimelineLive do
  use TryggWeb, :live_view

  alias Trygg.Accounts.Scope
  alias Trygg.Families
  alias Trygg.Log
  alias Trygg.Log.Entry
  alias TryggWeb.Loading

  @page_size 50
  @filters [nil, :feeding, :diaper, :sleep]

  # The finer breakdown offered once a type is picked: `{id, label, data}`,
  # where `data` is what an entry's `data` map must match
  # (see `Trygg.Log.list_entries/3`). Derived from the entry schema's allowed
  # values so a new bottle content, diaper kind or sleep place shows up here.
  @subfilters %{
    feeding:
      Enum.map(Entry.bottle_contents(), &{&1, String.capitalize(&1), %{"bottle_contents" => &1}}) ++
        [{"vitamin_d", "Vitamin D", %{"vitamin_d" => "true"}}],
    diaper: Enum.map(Entry.diaper_kinds(), &{&1, String.capitalize(&1), %{"kind" => &1}}),
    sleep: Enum.map(Entry.sleep_locations(), &{&1, String.capitalize(&1), %{"location" => &1}})
  }

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
      <%!-- Padded on every side so the scroller doesn't clip the chips' toy edge
           and focus ring; the negative margins give the room back. --%>
      <div class="-mx-4 -mt-1 flex gap-2 overflow-x-auto px-4 pb-2 pt-1">
        <.button
          :for={f <- filters()}
          type="button"
          variant={if @filter == f, do: "primary", else: nil}
          size="sm"
          id={"filter-#{f || "all"}"}
          phx-click={JS.push("filter", value: %{type: f && to_string(f)}, loading: "#log-entries")}
          class="shrink-0"
        >
          {filter_label(f)}
        </.button>
      </div>

      <div
        :if={subfilters(@filter) != []}
        id="log-subfilters"
        class="flex gap-2 overflow-x-auto pb-2 -mx-4 px-4"
      >
        <.button
          type="button"
          id="subfilter-all"
          variant={if @subfilter == nil, do: "neutral", else: nil}
          size="xs"
          phx-click={JS.push("subfilter", value: %{id: ""}, loading: "#log-entries")}
          class="shrink-0"
        >
          All
        </.button>
        <.button
          :for={{id, label, _data} <- subfilters(@filter)}
          type="button"
          id={"subfilter-#{id}"}
          variant={if @subfilter == id, do: "neutral", else: nil}
          size="xs"
          phx-click={JS.push("subfilter", value: %{id: id}, loading: "#log-entries")}
          class="shrink-0"
        >
          {label}
        </.button>
      </div>

      <.loadable
        id="log-entries"
        loaded={@loaded?}
        failed={@load_failed?}
        class="loading-dim"
      >
        <:skeleton><.entry_rows_skeleton count={8} show_date /></:skeleton>
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

        <div :if={@has_more?} class="py-4 text-center">
          <.button
            id="log-load-more"
            type="button"
            size="sm"
            phx-click="load_more"
            phx-disable-with="Loading…"
          >
            Load older entries
          </.button>
        </div>
        <p
          :if={!@has_more? && !@entries_empty?}
          id="log-end"
          class="py-6 text-center text-xs opacity-40"
        >
          That's everything.
        </p>
      </.loadable>

      <.edit_modal
        :if={@editing}
        entry={@editing}
        form={@edit_form}
        upload={@uploads.photo}
        vitamin_d?={@edit_vitamin_d?}
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
      |> assign(:subfilter, nil)
      |> assign(:has_more?, false)
      |> assign(:cursor, nil)
      |> assign(:loaded_count, 0)
      |> assign(:editing, nil)
      |> assign(:edit_vitamin_d?, false)
      |> assign(:edit_form, nil)
      |> allow_upload(:photo,
        accept: Log.photo_accept(),
        max_entries: 1,
        max_file_size: Log.max_photo_bytes(),
        auto_upload: true
      )
      |> assign(:entries_empty?, false)
      |> stream(:entries, [])
      |> Loading.init()
      |> load_entries()

    {:ok, socket}
  end

  @impl true
  def handle_async(:load, result, socket),
    do: {:noreply, Loading.done(socket, result, &apply_entries/2)}

  @impl true
  # A new entry joins the top of the list, so the reload window grows by one to
  # keep the oldest page-loaded entry on screen.
  def handle_info({:log, :created, _entry}, socket), do: {:noreply, load_entries(socket, 1)}
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
    filter = Enum.find(@filters, &(to_string(&1) == to_string(type)))

    {:noreply,
     socket
     |> assign(filter: filter, subfilter: nil, loaded_count: 0)
     |> load_entries()}
  end

  def handle_event("subfilter", %{"id" => id}, socket) do
    sub =
      Enum.find_value(subfilters(socket.assigns.filter), fn {sid, _, _} -> sid == id && id end)

    {:noreply, socket |> assign(subfilter: sub, loaded_count: 0) |> load_entries()}
  end

  def handle_event("load_more", _params, %{assigns: %{cursor: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("load_more", _params, socket) do
    {entries, more?} = fetch_page(socket, @page_size, socket.assigns.cursor)

    {:noreply,
     socket
     |> stream(:entries, entries)
     |> assign(
       has_more?: more?,
       cursor: cursor_after(entries, socket.assigns.cursor),
       loaded_count: socket.assigns.loaded_count + length(entries)
     )}
  end

  def handle_event("retry_load", _params, socket), do: {:noreply, load_entries(socket)}

  def handle_event("edit", %{"id" => id}, socket) do
    entry = Log.get_entry!(socket.assigns.current_scope, id)
    child = socket.assigns.current_child
    params = entry_edit_params(entry, child)

    {:noreply,
     socket
     |> clear_photo_upload()
     |> assign(editing: entry, edit_form: to_form(params, as: :entry))
     |> assign(:edit_vitamin_d?, offer_vitamin_d?(child, entry))}
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

  # The first load goes through `TryggWeb.Loading` (skeleton, then a task);
  # once the list is on screen, filter changes and realtime updates reload it
  # in place. A reload keeps as many entries on screen as were already loaded
  # (at least one page), so a live update doesn't snap the list back to the top.
  defp load_entries(socket, extra \\ 0) do
    fetch = fetch_fun(socket, max(socket.assigns.loaded_count + extra, @page_size), nil)

    if socket.assigns.loaded?,
      do: apply_entries(socket, fetch.()),
      else: Loading.run(socket, fetch, &apply_entries/2)
  end

  defp apply_entries(socket, {entries, more?}) do
    socket
    |> assign(
      entries_empty?: entries == [],
      has_more?: more?,
      cursor: cursor_after(entries, nil),
      loaded_count: length(entries)
    )
    |> stream(:entries, entries, reset: true)
  end

  defp fetch_page(socket, limit, cursor), do: fetch_fun(socket, limit, cursor).()

  # A zero-arity fetch capturing plain values only (it may run in a task).
  # Asks for one entry past `limit` to learn whether there's another page.
  defp fetch_fun(socket, limit, cursor) do
    %{current_scope: scope, current_child: child, filter: filter, subfilter: sub} = socket.assigns
    data = sub_data(filter, sub)

    fn ->
      entries =
        Log.list_entries(scope, child,
          type: filter,
          data: data,
          before: cursor,
          limit: limit + 1
        )

      {page, rest} = Enum.split(entries, limit)
      {page, rest != []}
    end
  end

  defp cursor_after([], cursor), do: cursor

  defp cursor_after(entries, _cursor) do
    last = List.last(entries)
    {last.started_at, last.id}
  end

  defp sub_data(filter, sub) do
    Enum.find_value(subfilters(filter), fn {id, _label, data} -> id == sub && data end)
  end

  defp subfilters(filter), do: Map.get(@subfilters, filter, [])
  defp filters, do: @filters
  defp filter_label(nil), do: "All"
  defp filter_label(:feeding), do: "Feeds"
  defp filter_label(:diaper), do: "Diapers"
  defp filter_label(:sleep), do: "Sleep"
end
