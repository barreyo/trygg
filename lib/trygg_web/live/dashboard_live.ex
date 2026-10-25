defmodule TryggWeb.DashboardLive do
  use TryggWeb, :live_view

  alias Trygg.{Devices, Families, Growth, Log, Notices, Push, Reports}
  alias Trygg.Accounts.Scope
  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias TryggWeb.UndoDelete
  alias Trygg.Reports.Alerts
  alias Trygg.Units
  alias TryggWeb.{Loading, RemoteUpdate}

  @recent_limit 20
  # A `:simple` member's Today: just the two things they can log.
  @simple_types [:feeding, :diaper]
  @tick_ms 60_000
  # How long a simple member's "Undo" stays up after a log (their celebration
  # takes the first couple of seconds), and how long "Undone" lingers.
  @take_back_ms 12_000
  @taken_back_ms 3_000
  @nudge_minutes [-5, -15, -30]
  @note_suggestions ["Peaceful", "Restless", "Short one", "Woke a lot"]

  ## Mount / redirect -----------------------------------------------------

  @impl true
  def mount(_params, _session, %{assigns: %{live_action: :index}} = socket) do
    case resume_child(socket.assigns.current_scope) do
      nil -> {:ok, push_navigate(socket, to: ~p"/children/new")}
      child -> {:ok, push_navigate(socket, to: ~p"/c/#{child}")}
    end
  end

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :tick, @tick_ms)
      Trygg.Accounts.subscribe_user(socket.assigns.current_scope.user.id)
      Devices.subscribe(socket.assigns.current_child.family_id)
    end

    scope = socket.assigns.current_scope
    child = socket.assigns.current_child

    socket =
      socket
      |> assign(:unit_system, scope.user.unit_system)
      |> assign(:can_write, child.role in [:owner, :caregiver])
      |> assign(:simple?, child.role == :simple)
      |> assign(:sheet, nil)
      |> assign(:sheet_form, nil)
      |> assign(:editing, nil)
      |> assign(:undo, nil)
      |> assign(:take_back, nil)
      |> assign(:edit_vitamin_d?, false)
      |> assign(:edit_form, nil)
      |> assign(:now_tick, System.system_time(:second))
      |> assign(:vapid_public_key, Push.vapid_public_key())
      |> assign(:dismissed_notices, MapSet.new())
      |> assign(summary: nil, outlook: nil, weight_reminder: nil, rhythm_center: nil)
      |> assign(:entries_empty?, false)
      |> assign(:devices, [])
      |> assign(:pinned, MapSet.new())
      |> stream(:entries, [])
      |> allow_upload(:photo,
        accept: Log.photo_accept(),
        max_entries: 1,
        max_file_size: Log.max_photo_bytes(),
        auto_upload: true
      )
      |> Loading.init()
      |> load()

    {:ok, socket}
  end

  # First load: skeleton on the static render, then fetched off the LiveView
  # process so the page (and its tab bar) is interactive straight away. See
  # `TryggWeb.Loading`.
  defp load(socket) do
    scope = socket.assigns.current_scope
    child = socket.assigns.current_child

    Loading.run(socket, fn -> fetch_home(scope, child) end, &apply_home/2)
  end

  @impl true
  def handle_async(:load, result, socket),
    do: {:noreply, Loading.done(socket, result, &apply_home/2)}

  # `/` has no child in the URL, so it reopens the one this caregiver was last
  # looking at (`users.last_child_id`) as long as they still have access —
  # otherwise their most recently added child. Without this, `/` (the PWA
  # start_url, and the back-button target from a child-scoped screen) would
  # silently jump the selection to whichever child was added last.
  defp resume_child(scope) do
    children = Families.list_children(scope)
    last_id = scope.user.last_child_id

    Enum.find(children, &(&1.id == last_id)) || List.first(children)
  end

  ## Realtime ---------------------------------------------------------------

  @impl true
  def handle_info({:log, action, entry}, socket),
    do: {:noreply, socket |> refresh() |> flash_remote(entry, action)}

  def handle_info({:growth, _action, _measurement}, socket),
    do: {:noreply, refresh_summary(socket)}

  def handle_info({:child_updated, child}, socket) do
    previous = socket.assigns.current_child.tracked_types

    {:noreply,
     socket
     |> assign(:current_child, %{child | role: socket.assigns.role})
     |> resync_layout_sheet(previous, child.tracked_types)
     |> refresh()}
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
    {:noreply, resync_membership(socket)}
  end

  # Room sensors: the family's few devices live in one list. A reading flashes
  # the pinned device's card, so a change on screen is easy to spot.
  def handle_info({:device_reading, device, _reading}, socket) do
    {:noreply,
     socket
     |> put_device(device)
     |> RemoteUpdate.flash_device(device)}
  end

  def handle_info({:device_changed, device}, socket), do: {:noreply, put_device(socket, device)}

  def handle_info({:device_deleted, id}, socket),
    do: {:noreply, update(socket, :devices, &Enum.reject(&1, fn d -> d.id == id end))}

  def handle_info({:user_updated, user}, socket) do
    scope = %{socket.assigns.current_scope | user: user}

    {:noreply,
     socket
     |> assign(:current_scope, scope)
     |> assign(:unit_system, user.unit_system)
     |> refresh()}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, socket |> assign(:now_tick, System.system_time(:second)) |> refresh_summary()}
  end

  def handle_info({:undo_expired, ref}, socket),
    do: {:noreply, UndoDelete.expire(socket, ref)}

  def handle_info({:take_back_expired, ref}, %{assigns: %{take_back: %{ref: ref}}} = socket),
    do: {:noreply, assign(socket, :take_back, nil)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # A change from elsewhere pulses its card, except in simple mode, which stays still.
  defp flash_remote(%{assigns: %{simple?: true}} = socket, _entry, _action), do: socket
  defp flash_remote(socket, entry, action), do: RemoteUpdate.flash_home(socket, entry, action)

  # Re-check the caller's role after a membership change: bounce them home if
  # they've lost access, otherwise fold the fresh role onto the socket so
  # write controls appear/disappear immediately.
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

        can_write = role in [:owner, :caregiver]
        simple? = role == :simple

        socket =
          socket
          |> assign(:role, role)
          |> assign(:can_write, can_write)
          |> assign(:current_child, child)
          |> assign(:current_scope, Scope.put_child(scope, child, role))

        cond do
          # Moved into or out of simple mode: a different screen with a
          # different recent list, so start it afresh.
          simple? != socket.assigns.simple? ->
            push_navigate(socket, to: ~p"/c/#{child}")

          can_write ->
            socket

          true ->
            assign(socket, editing: nil, edit_form: nil)
        end
    end
  end

  ## Sleep events -------------------------------------------------------

  @impl true
  def handle_event("start_sleep", _params, socket) do
    socket =
      case Log.start_timer(socket.assigns.current_scope, socket.assigns.current_child, :sleep) do
        {:ok, _} -> splash(socket, "sleep_start")
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_event("start_breastfeeding", _params, socket) do
    socket =
      case Log.start_timer(
             socket.assigns.current_scope,
             socket.assigns.current_child,
             :breastfeeding
           ) do
        {:ok, _} -> socket |> assign(sheet: nil, sheet_form: nil) |> splash("breastfeeding_start")
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_event("nudge_start", %{"by" => by, "type" => type}, socket) do
    case {type, Integer.parse(by)} do
      {type, {minutes, ""}} when type in ["sleep", "breastfeeding"] ->
        {:noreply, nudge_timer(socket, String.to_existing_atom(type), minutes)}

      _ ->
        {:noreply, socket}
    end
  end

  # Home alerts and the weight-check banner can be dismissed for a week. Stored
  # server-side (`Trygg.Notices`) rather than in localStorage so it holds in the
  # installed PWA, whose storage is separate from the browser's.
  def handle_event("dismiss_notice", %{"key" => key}, socket) when is_binary(key) do
    dismissed =
      Notices.dismiss(
        socket.assigns.current_scope,
        socket.assigns.current_child,
        String.split(key, ",")
      )

    {:noreply, assign(socket, :dismissed_notices, dismissed)}
  end

  def handle_event("request_stop", _params, socket) do
    child = socket.assigns.current_child

    form =
      to_form(
        %{
          "ended_at" => timer_end_input(child, Log.running(socket.assigns.summary, :sleep)),
          "note" => ""
        },
        as: :sleep
      )

    {:noreply, socket |> clear_photo_upload() |> assign(sheet: :sleep_stop, sheet_form: form)}
  end

  def handle_event("request_breastfeeding_stop", _params, socket) do
    child = socket.assigns.current_child

    form =
      to_form(
        %{
          "ended_at" =>
            timer_end_input(child, Log.running(socket.assigns.summary, :breastfeeding)),
          "pattern" => "",
          "note" => ""
        },
        as: :breastfeeding
      )

    {:noreply,
     socket |> clear_photo_upload() |> assign(sheet: :breastfeeding_stop, sheet_form: form)}
  end

  def handle_event("sheet_change", %{"sleep" => params}, socket) do
    {:noreply, assign(socket, :sheet_form, to_form(params, as: :sleep))}
  end

  def handle_event("sheet_change", %{"breastfeeding" => params}, socket) do
    {:noreply, assign(socket, :sheet_form, to_form(params, as: :breastfeeding))}
  end

  def handle_event("sheet_change", %{"entry" => params}, socket) do
    {:noreply, assign(socket, :sheet_form, to_form(params, as: :entry))}
  end

  def handle_event("save_sleep", %{"sleep" => params}, socket) do
    {:noreply, save_sleep(socket, socket.assigns.sheet, params)}
  end

  def handle_event("save_breastfeeding", %{"breastfeeding" => params}, socket) do
    {:noreply, save_breastfeeding(socket, params)}
  end

  ## Other quick actions ---------------------------------------------

  def handle_event("quick", %{"kind" => kind}, socket), do: {:noreply, quick_log(socket, kind)}

  # Pull-to-refresh gesture (see the `PullToRefresh` JS hook). LiveView already
  # streams changes over the socket, so this is really a "did I miss anything?"
  # re-sync. The empty reply is the hook's cue to release the spinner.
  def handle_event("refresh", _params, socket), do: {:reply, %{}, refresh(socket)}

  def handle_event("retry_load", _params, socket), do: {:noreply, load(socket)}

  def handle_event("open_sheet", %{"kind" => "earlier"}, socket) do
    {:noreply, assign(socket, sheet: :earlier, sheet_form: nil)}
  end

  def handle_event("open_sheet", %{"kind" => "layout"}, socket) do
    types = Enum.map(socket.assigns.current_child.tracked_types, &to_string/1)
    devices = socket.assigns.pinned |> Enum.map(&to_string/1)

    {:noreply,
     assign(socket,
       sheet: :layout,
       sheet_form: layout_form(layout_order(types), types, devices)
     )}
  end

  def handle_event("open_sheet", %{"kind" => "bottle"}, socket) do
    last = socket.assigns.summary.last_feeding

    form =
      to_form(
        %{
          "at" => Child.to_local_input(socket.assigns.current_child, now()),
          "bottle_contents" => last_bottle_contents(last),
          "amount" => trim(last_bottle_amount(last, socket.assigns.unit_system)),
          "vitamin_d" => "false",
          "note" => ""
        },
        as: :entry
      )

    socket =
      socket
      |> clear_photo_upload()
      |> assign(sheet: :bottle, sheet_form: form)

    {:noreply, socket}
  end

  # Simple mode's bottle: just an amount, seeded from the last feed. What the
  # last bottle held carries over unseen, and the time is always now.
  def handle_event("open_sheet", %{"kind" => "bottle_simple"}, socket) do
    last = socket.assigns.summary.last_feeding

    form =
      to_form(
        %{
          "bottle_contents" => last_bottle_contents(last),
          "amount" => trim(last_bottle_amount(last, socket.assigns.unit_system))
        },
        as: :entry
      )

    {:noreply, assign(socket, sheet: :bottle_simple, sheet_form: form)}
  end

  def handle_event("open_sheet", %{"kind" => "sleep_start"}, socket) do
    case Log.running(socket.assigns.summary, :sleep) do
      %Entry{} = nap ->
        form =
          to_form(
            %{"started_at" => Child.to_local_input(socket.assigns.current_child, nap.started_at)},
            as: :sleep
          )

        {:noreply,
         socket |> clear_photo_upload() |> assign(sheet: :sleep_start, sheet_form: form)}

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

    {:noreply, socket |> clear_photo_upload() |> assign(sheet: :sleep_past, sheet_form: form)}
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

    {:noreply, socket |> clear_photo_upload() |> assign(sheet: :diaper_past, sheet_form: form)}
  end

  def handle_event("save_layout", %{"layout" => params}, socket) do
    order = layout_order(List.wrap(params["order"]))
    checked = checked_types(params)
    devices = checked_devices(params)

    # The submitted order is the new Home order; unticked trackers drop out of it
    wanted =
      for name <- order,
          name in checked,
          type <- Child.tracked_types(),
          to_string(type) == name,
          do: type

    case Families.update_tracked_types(
           socket.assigns.current_scope,
           socket.assigns.current_child,
           wanted
         ) do
      {:ok, child} ->
        # The pinned devices are this user's own, not the child's: pinning one leaves
        # everyone else's Today as it was.
        Devices.set_today_devices(socket.assigns.current_scope, child.family_id, devices)

        {:noreply,
         socket
         |> assign(:current_child, child)
         |> assign(sheet: nil, sheet_form: nil)
         |> refresh_devices()
         |> refresh()}

      {:error, _changeset} ->
        {:noreply,
         assign(socket,
           sheet_form:
             layout_form(
               order,
               checked,
               devices,
               tracked_types: {"pick at least one thing to track", []}
             )
         )}
    end
  end

  def handle_event("close_sheet", _params, socket) do
    {:noreply, socket |> clear_photo_upload() |> assign(sheet: nil, sheet_form: nil)}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    entry = Log.get_entry!(socket.assigns.current_scope, id)
    child = socket.assigns.current_child
    params = entry_edit_params(entry, child)

    {:noreply,
     socket
     |> clear_photo_upload()
     |> assign(sheet: nil, sheet_form: nil)
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
    params = Map.merge(params, consume_photo(socket))

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
    {:ok, deleted} =
      Log.delete_entry(socket.assigns.current_scope, socket.assigns.editing, undoable: true)

    {:noreply, socket |> assign(editing: nil, edit_form: nil) |> UndoDelete.stash(deleted)}
  end

  # A simple member's "Undo" on what they just logged: removes only that entry.
  def handle_event(
        "take_back",
        _params,
        %{assigns: %{take_back: %{entry: %Entry{} = entry}}} = socket
      ) do
    case Log.take_back_entry(socket.assigns.current_scope, entry) do
      {:error, :not_allowed} ->
        {:noreply,
         socket
         |> assign(:take_back, nil)
         |> put_flash(:error, "It's too late to undo that one.")}

      _removed_or_already_gone ->
        {:noreply, offer_taken_back(socket)}
    end
  end

  def handle_event("take_back", _params, socket), do: {:noreply, socket}

  def handle_event("undo_delete", _params, socket) do
    scope = socket.assigns.current_scope
    {entry, socket} = UndoDelete.take(socket)
    {:noreply, UndoDelete.restore(socket, entry, &Log.restore_entry(scope, &1))}
  end

  def handle_event("save_sheet", %{"entry" => params}, socket) do
    units = socket.assigns.unit_system
    child = socket.assigns.current_child
    ml = Units.from_display(parse_number(params["amount"]) || 0, :volume, units)

    result =
      with {:ok, at} <- Child.from_local_input(child, params["at"] || ""),
           :ok <- not_future(at) do
        Log.create_entry(
          socket.assigns.current_scope,
          child,
          :feeding,
          Map.merge(
            %{
              "type" => "feeding",
              "started_at" => at,
              "data" => %{
                "bottle_contents" => params["bottle_contents"],
                "amount_ml" => ml,
                "vitamin_d" => params["vitamin_d"]
              },
              "note" => blank(params["note"])
            },
            consume_photo(socket)
          )
        )
      end

    {:noreply, settle_feed(socket, result)}
  end

  def handle_event("save_bottle_now", %{"entry" => params}, socket) do
    units = socket.assigns.unit_system
    ml = Units.from_display(parse_number(params["amount"]) || 0, :volume, units)

    result =
      if ml > 0 do
        Log.create_entry(socket.assigns.current_scope, socket.assigns.current_child, :feeding, %{
          "data" => %{"bottle_contents" => params["bottle_contents"], "amount_ml" => ml}
        })
      else
        {:error, :no_amount}
      end

    {:noreply, settle_feed(socket, result)}
  end

  def handle_event("save_diaper", %{"entry" => params}, socket) do
    child = socket.assigns.current_child

    result =
      with {:ok, started} <- Child.from_local_input(child, params["started_at"] || ""),
           :ok <- not_future(started) do
        Log.create_entry(
          socket.assigns.current_scope,
          child,
          :diaper,
          Map.merge(
            %{
              "started_at" => started,
              "data" => %{"kind" => params["kind"]},
              "note" => blank(params["note"])
            },
            consume_photo(socket)
          )
        )
      end

    {:noreply, settle_diaper(socket, result)}
  end

  defp settle_diaper(socket, {:ok, entry}),
    do:
      socket
      |> assign(sheet: nil, sheet_form: nil)
      |> put_flash(:info, "Added that diaper.")
      |> splash("diaper_#{entry.data["kind"]}")

  defp settle_diaper(socket, {:error, :future}),
    do: put_flash(socket, :error, "That's in the future — pick an earlier time.")

  defp settle_diaper(socket, :error),
    do: put_flash(socket, :error, "That date and time didn't look right.")

  defp settle_diaper(socket, {:error, _}),
    do: put_flash(socket, :error, "Hmm, that didn't save — try again.")

  defp settle_feed(socket, {:ok, entry}),
    do:
      socket
      |> assign(sheet: nil, sheet_form: nil)
      |> put_flash(:info, "Saved.")
      |> logged(entry, "bottle")

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
           %Entry{} = nap <- Log.running(socket.assigns.summary, :sleep),
           :ok <- end_after_start(ended, nap.started_at) do
        Log.stop_timer(
          scope,
          nap,
          Map.merge(
            %{"ended_at" => ended, "note" => blank(params["note"])},
            consume_photo(socket)
          )
        )
      end

    settle(socket, result, "Sleep saved — sweet dreams.", "sleep_stop")
  end

  defp save_sleep(socket, :sleep_start, params) do
    scope = socket.assigns.current_scope

    result =
      with {:ok, started} <-
             Child.from_local_input(socket.assigns.current_child, params["started_at"] || ""),
           :ok <- not_future(started),
           %Entry{} = nap <- Log.running(socket.assigns.summary, :sleep) do
        Log.retime_entry(scope, nap, %{"started_at" => started})
      end

    settle(socket, result, "Updated the start time.", nil)
  end

  defp save_sleep(socket, :sleep_past, params) do
    child = socket.assigns.current_child

    result =
      with {:ok, started} <- Child.from_local_input(child, params["started_at"] || ""),
           {:ok, ended} <- Child.from_local_input(child, params["ended_at"] || ""),
           :ok <- end_after_start(ended, started) do
        Log.create_entry(
          socket.assigns.current_scope,
          child,
          :sleep,
          Map.merge(
            %{
              "started_at" => started,
              "ended_at" => ended,
              "note" => blank(params["note"])
            },
            consume_photo(socket)
          )
        )
      end

    settle(socket, result, "Added that sleep.", "sleep_stop")
  end

  defp save_breastfeeding(socket, params) do
    result =
      with {:ok, ended} <-
             Child.from_local_input(socket.assigns.current_child, params["ended_at"] || ""),
           %Entry{} = feed <- Log.running(socket.assigns.summary, :breastfeeding),
           :ok <- end_after_start(ended, feed.started_at) do
        Log.stop_timer(
          socket.assigns.current_scope,
          feed,
          Map.merge(
            %{
              "ended_at" => ended,
              "note" => blank(params["note"]),
              "data" => %{"pattern" => params["pattern"]}
            },
            consume_photo(socket)
          )
        )
      end

    settle(socket, result, "Breastfeeding saved.", "breastfeeding_stop")
  end

  defp settle(socket, {:ok, _}, msg, splash_kind) do
    socket = socket |> assign(sheet: nil, sheet_form: nil) |> put_flash(:info, msg)
    if splash_kind, do: splash(socket, splash_kind), else: socket
  end

  defp settle(socket, {:error, %Ecto.Changeset{}}, _msg, _splash),
    do: put_flash(socket, :error, "Their wake-up time needs to be after they fell asleep.")

  defp settle(socket, {:error, :future}, _msg, _splash),
    do: put_flash(socket, :error, "That's in the future — pick an earlier time.")

  defp settle(socket, {:error, :end_before_start}, _msg, _splash),
    do: put_flash(socket, :error, "Finish time must be after the start time.")

  defp settle(socket, nil, _msg, _splash),
    do: socket |> assign(sheet: nil) |> put_flash(:error, "There's no sleep to update right now.")

  defp settle(socket, :error, _msg, _splash),
    do: put_flash(socket, :error, "That date and time didn't look right.")

  defp end_after_start(ended, started) do
    if DateTime.after?(ended, started), do: :ok, else: {:error, :end_before_start}
  end

  defp timer_end_input(child, %Entry{started_at: started}) do
    now = now()

    rounded_now =
      case Child.from_local_input(child, Child.to_local_input(child, now)) do
        {:ok, ended} -> ended
        _ -> now
      end

    ended =
      if DateTime.after?(rounded_now, started),
        do: rounded_now,
        else: DateTime.add(started, 60, :second)

    Child.to_local_input(child, ended)
  end

  defp timer_end_input(child, _timer), do: Child.to_local_input(child, now())

  defp nudge_timer(socket, type, minutes) do
    case Log.running(socket.assigns.summary, type) do
      %Entry{} = timer ->
        new_start = DateTime.add(timer.started_at, minutes * 60, :second)

        cond do
          DateTime.compare(new_start, DateTime.utc_now()) == :gt ->
            put_flash(socket, :error, "That would put the start in the future.")

          DateTime.diff(DateTime.utc_now(), new_start, :second) > 86_400 ->
            put_flash(socket, :error, "That's more than a day back — use Edit for that.")

          true ->
            case Log.retime_entry(socket.assigns.current_scope, timer, %{
                   "started_at" => new_start
                 }) do
              {:ok, _} -> socket
              {:error, _} -> put_flash(socket, :error, "Couldn't change the start time.")
            end
        end

      nil ->
        socket
    end
  end

  ## Helpers ------------------------------------------------------------

  defp quick_log(socket, "diaper_" <> kind) do
    result =
      Log.create_entry(socket.assigns.current_scope, socket.assigns.current_child, :diaper, %{
        "data" => %{"kind" => kind}
      })

    case result do
      {:ok, entry} -> socket |> put_flash(:info, "Saved.") |> logged(entry, "diaper_#{kind}")
      _ -> put_flash(socket, :error, "Hmm, that didn't save — try again.")
    end
  end

  # Plays the full-screen celebration for a log this caregiver just made (see
  # `assets/js/log_splash.js`). It also keeps the screen untappable for a beat,
  # so a fast double tap can't log the same thing twice. Only for the caregiver's
  # own taps: changes from elsewhere pulse instead (`TryggWeb.RemoteUpdate`).
  defp splash(socket, kind), do: push_event(socket, "log-splash", %{kind: kind})

  # Simple mode: the celebration says what was logged in plain words (instead
  # of a joke caption), and the screen offers to take it back for a while.
  defp logged(%{assigns: %{simple?: true}} = socket, %Entry{} = entry, kind) do
    label = log_confirmation(entry, socket.assigns.current_child, socket.assigns.unit_system)

    socket
    |> push_event("log-splash", %{kind: kind, label: label})
    |> offer_take_back(entry, label)
  end

  defp logged(socket, _entry, kind), do: splash(socket, kind)

  defp offer_take_back(socket, entry, label),
    do: put_take_back(socket, %{entry: entry, label: label}, @take_back_ms)

  defp offer_taken_back(socket),
    do: put_take_back(socket, %{entry: nil, label: "Undone"}, @taken_back_ms)

  defp put_take_back(socket, offer, ms) do
    ref = System.unique_integer([:positive])

    if connected?(socket), do: Process.send_after(self(), {:take_back_expired, ref}, ms)

    assign(socket, :take_back, Map.put(offer, :ref, ref))
  end

  defp log_confirmation(%Entry{type: :diaper} = entry, child, _units),
    do:
      "#{String.capitalize(entry.data["kind"])} logged at #{Child.local_clock(child, entry.started_at)}"

  defp log_confirmation(%Entry{} = entry, child, units),
    do:
      "Bottle logged at #{Child.local_clock(child, entry.started_at)} · " <>
        Units.format(entry.data["amount_ml"], :volume, units)

  defp consume_photo(socket), do: consume_photo(socket, socket.assigns.current_child)

  # Anything that changes before the first load lands just restarts it, so
  # the result that does land is never older than the change.
  defp refresh(%{assigns: %{loaded?: false}} = socket), do: load(socket)
  defp refresh(socket), do: socket |> refresh_summary() |> refresh_entries()

  defp fetch_home(scope, child) do
    %{
      status: fetch_status(scope, child),
      entries: recent_tracked(scope, child, @recent_limit),
      devices: Devices.list_devices(scope, child.family_id),
      pinned: Devices.pinned_ids(scope, child.family_id)
    }
  end

  defp apply_home(socket, %{status: status, entries: entries, devices: devices, pinned: pinned}) do
    socket
    |> apply_status(status)
    |> apply_entries(entries)
    |> assign(devices: devices, pinned: pinned)
  end

  # After this user pinned or unpinned devices: their alerts only load for pinned ones.
  defp refresh_devices(socket) do
    scope = socket.assigns.current_scope
    family_id = socket.assigns.current_child.family_id

    assign(socket,
      devices: Devices.list_devices(scope, family_id),
      pinned: Devices.pinned_ids(scope, family_id)
    )
  end

  # Replaces the device in the list (devices are ordered by id) or adds it. A
  # message that only carries the sample or the rename keeps the other half of
  # what the list already knows.
  defp put_device(socket, device) do
    update(socket, :devices, fn devices ->
      devices
      |> Enum.reject(&(&1.id == device.id))
      |> Kernel.++([device])
      |> Enum.sort_by(& &1.id)
    end)
  end

  defp today_devices(devices, pinned), do: Enum.filter(devices, &MapSet.member?(pinned, &1.id))

  # The at-a-glance numbers (counts, "slept today", "Xm ago") plus the outlook
  # (next nap / next feed / alerts). Recomputed on every minute tick so
  # time-derived figures advance without waiting for the next logged event.
  defp refresh_summary(%{assigns: %{loaded?: false}} = socket), do: load(socket)

  defp refresh_summary(socket) do
    apply_status(
      socket,
      fetch_status(socket.assigns.current_scope, socket.assigns.current_child)
    )
  end

  defp fetch_status(scope, child) do
    %{
      summary: Log.summary(scope, child),
      outlook: Reports.outlook(scope, child),
      weight_reminder: Growth.weight_check_reminder(scope, child),
      dismissed_notices: Notices.dismissed(scope, child)
    }
  end

  defp apply_status(socket, %{summary: summary} = status) do
    socket
    |> assign(:summary, summary)
    |> assign(:outlook, status.outlook)
    |> assign(:weight_reminder, status.weight_reminder)
    |> assign(:dismissed_notices, status.dismissed_notices)
    |> assign_rhythm_center()
    |> push_offline_snapshot(socket.assigns.current_scope, socket.assigns.current_child, summary)
  end

  # The single most actionable thing, for the middle of the rhythm dial: a
  # running sleep timer wins, then the next predicted nap (tinted amber once
  # they're past their usual window), then bedtime when the naps are done,
  # then a plain "awake since" / "slept so far".
  defp assign_rhythm_center(socket) do
    assign(socket, :rhythm_center, rhythm_center(socket.assigns))
  end

  defp rhythm_center(%{summary: summary, outlook: outlook, current_child: child}) do
    cond do
      e = Log.running(summary, :sleep) ->
        %{
          eyebrow: "Asleep",
          since_unix: DateTime.to_unix(e.started_at),
          detail: "since #{Child.local_clock(child, e.started_at)}",
          tone: :success
        }

      nap = awake_next_nap(outlook) ->
        %{
          eyebrow: "Next nap",
          big: nap.label,
          detail: due_label(nap.in_seconds),
          tone: if(match?(%{state: :past}, wake_pressure(outlook)), do: :warning, else: :primary)
        }

      bed = awake_bedtime(outlook) ->
        %{
          eyebrow: "Bedtime",
          big: bed.label,
          detail: due_label(DateTime.diff(bed.at, now(), :second)),
          tone: :primary
        }

      woke = woke_at(summary) ->
        %{
          eyebrow: "Awake",
          big: format_duration(DateTime.diff(now(), woke, :second)),
          detail: "since #{Child.local_clock(child, woke)}",
          tone: :base
        }

      true ->
        %{
          eyebrow: "Slept today",
          big: format_duration(summary.today.sleep_seconds),
          detail: "so far",
          tone: :base
        }
    end
  end

  defp awake_next_nap(%{prediction: %{state: :awake, next_nap: %{} = nap}}), do: nap
  defp awake_next_nap(_), do: nil

  defp awake_bedtime(%{
         prediction: %{state: :awake, next_nap: nil, bedtime: %{at: %DateTime{}} = b}
       }),
       do: b

  defp awake_bedtime(_), do: nil

  # Mirror a compact read cache to the client (via the OfflineContext hook →
  # IndexedDB) so the offline quick-logger can show recent activity and a
  # running sleep timer while there's no socket. Only meaningful once
  # connected; the static mount has nothing to push to.
  defp push_offline_snapshot(socket, scope, child, summary) do
    if connected?(socket) do
      unit = socket.assigns.unit_system

      push_event(socket, "offline:snapshot", %{
        running:
          Enum.map(summary.running, fn e ->
            %{id: e.id, type: e.type, started_at: DateTime.to_iso8601(e.started_at)}
          end),
        recent:
          scope
          |> recent_tracked(child, 8)
          |> Enum.map(fn e ->
            %{
              type: e.type,
              at: DateTime.to_iso8601(e.started_at),
              text: snapshot_line(e, unit)
            }
          end)
      })
    else
      socket
    end
  end

  defp snapshot_line(%Entry{type: :feeding, data: data}, unit) do
    case data["amount_ml"] do
      ml when is_number(ml) -> "Bottle · " <> Units.format(ml, :volume, unit)
      _ -> "Bottle"
    end
  end

  defp snapshot_line(%Entry{type: :diaper, data: %{"kind" => kind}}, _unit),
    do: String.capitalize(kind) <> " diaper"

  defp snapshot_line(%Entry{type: :diaper}, _unit), do: "Diaper"
  defp snapshot_line(%Entry{type: :sleep, ended_at: nil}, _unit), do: "Sleeping"

  defp snapshot_line(%Entry{type: :sleep} = entry, _unit),
    do: "Slept " <> format_duration(Entry.duration_seconds(entry))

  defp snapshot_line(%Entry{type: :breastfeeding, ended_at: nil}, _unit),
    do: "Breastfeeding"

  defp snapshot_line(%Entry{type: :breastfeeding, data: %{"pattern" => pattern}} = entry, _unit),
    do:
      "Breastfed · #{Entry.breastfeeding_pattern_label(pattern)} · #{format_duration(Entry.duration_seconds(entry))}"

  defp snapshot_line(%Entry{type: :breastfeeding} = entry, _unit),
    do: "Breastfed · #{format_duration(Entry.duration_seconds(entry))}"

  defp refresh_entries(socket) do
    scope = socket.assigns.current_scope
    child = socket.assigns.current_child
    apply_entries(socket, recent_tracked(scope, child, @recent_limit))
  end

  # Recent activity limited to what this child's Home tracks, so a hidden
  # tracker's old entries don't linger in the list.
  defp recent_tracked(_scope, %Child{role: :simple}, _limit), do: []

  defp recent_tracked(scope, child, limit),
    do: Log.list_entries(scope, child, limit: limit, types: child.tracked_types)

  defp apply_entries(socket, entries) do
    socket
    |> assign(:entries_empty?, entries == [])
    |> stream(:entries, entries, reset: true)
  end

  # Someone else rearranged Home while this device has the Customize sheet open:
  # show the arrangement that is now live, so saving can't quietly undo it.
  defp resync_layout_sheet(%{assigns: %{sheet: :layout}} = socket, previous, current)
       when previous != current do
    types = Enum.map(current, &to_string/1)
    devices = List.wrap(socket.assigns.sheet_form.params["devices"])
    assign(socket, :sheet_form, layout_form(layout_order(types), types, devices))
  end

  defp resync_layout_sheet(socket, _previous, _current), do: socket

  # `order` is every tracker in display order, `checked` the ones switched on.
  # `devices` are the ids of the room sensors pinned to Today.
  defp layout_form(order, checked, devices, errors \\ []),
    do:
      to_form(%{"order" => order, "tracked_types" => checked, "devices" => devices},
        as: :layout,
        errors: errors
      )

  # Valid, unique tracker names in the given order, with any missing ones
  # appended so every tracker always has a row.
  defp layout_order(names) do
    all = Enum.map(Child.tracked_types(), &to_string/1)
    Enum.uniq(Enum.filter(names, &(&1 in all)) ++ all)
  end

  defp checked_types(params),
    do: params["tracked_types"] |> List.wrap() |> Enum.reject(&(&1 == ""))

  defp checked_devices(params),
    do: params["devices"] |> List.wrap() |> Enum.reject(&(&1 == ""))

  defp tracker_label(name),
    do:
      Enum.find_value(Child.tracker_options(), fn {type, label} ->
        to_string(type) == name && label
      end)

  # Accessible name of each sheet — the same words as its on-screen heading.
  defp sheet_label(:earlier), do: "Log from earlier"
  defp sheet_label(:layout), do: "Customize Today"
  defp sheet_label(:bottle), do: "Log a bottle"
  defp sheet_label(:bottle_simple), do: "Log a bottle"
  defp sheet_label(:sleep_stop), do: "How did they sleep?"
  defp sheet_label(:sleep_start), do: "When did they fall asleep?"
  defp sheet_label(:sleep_past), do: "Add a sleep from earlier"
  defp sheet_label(:breastfeeding_stop), do: "Finished feeding"
  defp sheet_label(:diaper_past), do: "Add a diaper from earlier"

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

  defp fine_step(:metric), do: 5
  defp fine_step(:imperial), do: 0.5

  defp parse_number(nil), do: nil
  defp parse_number(""), do: nil

  defp parse_number(s) when is_binary(s) do
    case Float.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_number(n) when is_number(n), do: n * 1.0

  ## Render -------------------------------------------------------------

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} title="Trygg">
      <.loadable id="home-resume" loaded={false}>
        <:skeleton><.home_status_skeleton /></:skeleton>
      </.loadable>
    </Layouts.app>
    """
  end

  # Simple mode (`:simple` members): Today with just the bottle and the diaper
  # cards, each logging as it happens. No recent list, alerts, devices,
  # customizing, back-dating, editing or links to other pages.
  def render(%{simple?: true} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_child={@current_child}
      current_tab={:home}
      title={@current_child.name}
      subtitle={Child.caption(@current_child)}
      children={@children}
    >
      <.pull_to_refresh />

      <.loadable id="home-status" loaded={@loaded?} failed={@load_failed?}>
        <:skeleton>
          <.home_status_skeleton types={simple_types()} footer={false} />
        </:skeleton>
        <section id="glance-cards" class="space-y-3">
          <.glance
            :for={{type, i} <- Enum.with_index(simple_types())}
            type={type}
            index={i}
            summary={@summary}
            outlook={@outlook}
            current_child={@current_child}
            unit_system={@unit_system}
            can_write={false}
            simple?
          />
        </section>
      </.loadable>

      <.sheet
        :if={@sheet}
        kind={@sheet}
        form={@sheet_form}
        unit_system={@unit_system}
        photo_upload={@uploads.photo}
        timezone={@current_child.timezone}
      />
      <.take_back_toast take_back={@take_back} />
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_child={@current_child}
      current_tab={:home}
      title={@current_child.name}
      subtitle={Child.caption(@current_child)}
      children={@children}
      wide
    >
      <%!-- Mirrors which child / units / write-access into IndexedDB so the
           offline quick-logger (served with no live socket) knows what it's
           logging for. See assets/js/hooks/offline_context.js. --%>
      <div
        id="offline-context"
        phx-hook="OfflineContext"
        hidden
        data-child-id={@current_child.id}
        data-child-name={@current_child.name}
        data-unit-system={@unit_system}
        data-can-write={to_string(@can_write)}
        data-tz={@current_child.timezone}
        data-tracked-types={Enum.join(@current_child.tracked_types, ",")}
      />

      <.pull_to_refresh />

      <%!-- Status and quick actions on the left, the recent log beside them
           once there is room (stacked on phones). --%>
      <Layouts.columns id="home-columns">
        <:left>
          <.loadable id="home-status" loaded={@loaded?} failed={@load_failed?}>
            <:skeleton>
              <.home_status_skeleton
                can_write={@can_write}
                types={@current_child.tracked_types}
              />
            </:skeleton>
            <%!-- Typical-day dial: the child's rhythm at a glance, with the next
               actionable moment (or a running timer) called out in the middle.
               Hidden for now — not needed yet. --%>
            <%!--
          <.rhythm_dial
            rhythm={@outlook.rhythm}
            center={@rhythm_center}
            child_name={@current_child.name}
          />
          --%>

            <%!-- Health alerts — the first thing a caregiver should see after the
               header/active timer, so this sits above everything else, including
               the glance cards. Only warnings and notices get the full card;
               informational ones ("eating more than usual") collapse to a
               one-line pointer to Reports so they don't crowd the screen. --%>
            <div id="home-notices">
              <div :if={@outlook.alerts != []} class="mb-4 space-y-2">
                <.alerts_list
                  id="home-alerts"
                  alerts={
                    visible_alerts(
                      @outlook.alerts,
                      @dismissed_notices,
                      @current_child,
                      &(&1.severity != :info)
                    )
                  }
                  on_dismiss="dismiss_notice"
                  links={
                    %{
                      vitals: ~p"/c/#{@current_child}/vitals",
                      reports: ~p"/c/#{@current_child}/reports"
                    }
                  }
                />
                <.alerts_note
                  id="home-info-alerts"
                  alerts={
                    visible_alerts(
                      @outlook.alerts,
                      @dismissed_notices,
                      @current_child,
                      &(&1.severity == :info)
                    )
                  }
                  navigate={~p"/c/#{@current_child}/reports?view=trends"}
                  on_dismiss="dismiss_notice"
                />
              </div>

              <%!-- Weight-check reminder — CDC well-child cadence, also emailed to caregivers --%>
              <div
                :if={@weight_reminder && "weight-check" not in @dismissed_notices}
                id="weight-check-reminder"
                class="glance-pop mb-4 flex items-start gap-3 rounded-[var(--radius-card)] border-2 border-warning/40 bg-warning/10 p-4"
              >
                <.icon name="hero-scale" class="size-5 shrink-0 mt-0.5 text-warning" />
                <div class="min-w-0 flex-1">
                  <p class="text-base font-bold leading-tight">Time for a weight check</p>
                  <p class="text-sm opacity-80 mt-0.5 leading-snug">
                    {weight_reminder_detail(@weight_reminder)}
                  </p>
                  <.link
                    navigate={~p"/c/#{@current_child}/vitals"}
                    class="mt-1 inline-flex items-center gap-0.5 text-sm text-primary underline underline-offset-2"
                  >
                    Log it in Vitals <.icon name="hero-arrow-right" class="size-3" />
                  </.link>
                </div>
                <.button
                  id="weight-check-reminder-dismiss"
                  type="button"
                  variant="ghost"
                  size="xs"
                  phx-click="dismiss_notice"
                  phx-value-key="weight-check"
                  class="btn-circle -mr-1 -mt-1 shrink-0"
                  aria-label="Dismiss weight check reminder"
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </.button>
              </div>
            </div>

            <%!-- At a glance: big, friendly cards stacked full width. Each card
               carries the buttons that log the next one of its kind, so the
               answer ("when was the last diaper?") and the action sit together
               and nothing important is a scroll away on a phone. --%>
            <section id="glance-cards" class="space-y-3">
              <.glance
                :for={{type, i} <- Enum.with_index(@current_child.tracked_types)}
                type={type}
                index={i}
                summary={@summary}
                outlook={@outlook}
                current_child={@current_child}
                unit_system={@unit_system}
                can_write={@can_write}
              />
            </section>

            <%!-- Room sensors pinned to Today (Customize, or Devices in the menu).
               They update as readings arrive. --%>
            <section
              :if={today_devices(@devices, @pinned) != []}
              id="today-devices"
              class="mt-3 space-y-3"
            >
              <.device_widget
                :for={{device, i} <- Enum.with_index(today_devices(@devices, @pinned))}
                device={device}
                unit_system={@unit_system}
                navigate={~p"/c/#{@current_child}/devices/#{device.id}"}
                index={length(@current_child.tracked_types) + i}
                now={@now_tick}
              />
            </section>

            <%!-- The odd ones out — rare enough to stay small --%>
            <div :if={@can_write} class="mt-3 flex items-center justify-center gap-1">
              <.button
                type="button"
                variant="ghost"
                size="sm"
                phx-click="open_sheet"
                phx-value-kind="earlier"
              >
                <.icon name="hero-clock" class="size-4" /> Log from earlier
              </.button>
              <.button
                id="customize-home"
                type="button"
                variant="ghost"
                size="sm"
                phx-click="open_sheet"
                phx-value-kind="layout"
              >
                <.icon name="hero-adjustments-horizontal" class="size-4" /> Customize
              </.button>
            </div>
          </.loadable>

          <%!-- One-time nudge to turn on push notifications. Rendered hidden; the
               PushPrompt hook reveals it only when the browser supports Web Push,
               permission is still undecided, and the caregiver hasn't answered
               before. Re-enabling later lives on Preferences. Placed below the
               quick actions so it never pushes vital stats down the screen. --%>
          <div
            :if={@vapid_public_key}
            id="push-prompt"
            phx-hook="PushPrompt"
            phx-update="ignore"
            hidden
            data-vapid-key={@vapid_public_key}
            class="mt-6 flex items-start gap-3 rounded-[var(--radius-card)] border-2 border-base-300 bg-base-200 p-4 text-base"
          >
            <.icon name="hero-bell-alert" class="size-5 shrink-0 mt-0.5 text-primary" />
            <div class="flex-1 min-w-0 space-y-2">
              <p class="font-medium">Turn on notifications?</p>
              <p class="opacity-70">
                Get a gentle heads-up on this device — like a weight check coming due — even when Trygg is closed.
              </p>
              <div class="flex gap-2">
                <.button
                  type="button"
                  variant="primary"
                  size="sm"
                  data-push-prompt-action="enable"
                >
                  Turn on
                </.button>
                <.button
                  type="button"
                  variant="ghost"
                  size="sm"
                  data-push-prompt-action="dismiss"
                >
                  Not now
                </.button>
              </div>
            </div>
            <.button
              type="button"
              variant="ghost"
              size="xs"
              class="btn-circle -mr-1 -mt-1"
              aria-label="Dismiss"
              data-push-prompt-action="dismiss"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </.button>
          </div>
        </:left>
        <:right>
          <div class="mt-8 md:mt-0 flex items-center justify-between border-b border-base-300 pb-2">
            <h2 class="font-semibold">Recent</h2>
            <.link
              navigate={~p"/c/#{@current_child}/log"}
              class="text-sm text-primary hover:underline"
            >
              Full log →
            </.link>
          </div>

          <.loadable id="home-recent" loaded={@loaded?} failed={@load_failed?} retry={false}>
            <:skeleton><.entry_rows_skeleton count={5} /></:skeleton>
            <p :if={@entries_empty?} class="opacity-70 text-sm py-6 text-center">
              Nothing tracked yet today — tap a button to start.
            </p>

            <div id="entries" phx-update="stream" class="divide-y divide-base-300">
              <.entry_row
                :for={{dom_id, entry} <- @streams.entries}
                id={dom_id}
                entry={entry}
                unit_system={@unit_system}
                tz={@current_child.timezone}
                photo_src={entry.photo_key && ~p"/c/#{@current_child}/log/#{entry.id}/photo"}
                on_click={@can_write && JS.push("edit", value: %{id: entry.id})}
              />
            </div>
          </.loadable>
        </:right>
      </Layouts.columns>

      <.sheet
        :if={@sheet}
        kind={@sheet}
        form={@sheet_form}
        unit_system={@unit_system}
        photo_upload={@uploads.photo}
        vitamin_d_prompt?={vitamin_d_prompt?(@current_child, @summary)}
        tracked_types={@current_child.tracked_types}
        devices={@devices}
        timezone={@current_child.timezone}
      />

      <.edit_modal
        :if={@editing}
        entry={@editing}
        form={@edit_form}
        upload={@uploads.photo}
        vitamin_d?={@edit_vitamin_d?}
        photo_src={@editing.photo_key && ~p"/c/#{@current_child}/log/#{@editing.id}/photo"}
      />
      <.undo_toast undo={@undo} label="Entry deleted" />
    </Layouts.app>
    """
  end

  ## Small render components ---------------------------------------------

  # Pull-to-refresh: a standalone PWA has no native pull-to-refresh, so this
  # inert sentinel's `PullToRefresh` hook drives the gesture on <main> and
  # pushes `refresh`.
  defp pull_to_refresh(assigns) do
    ~H"""
    <div id="pull-to-refresh" phx-hook="PullToRefresh" class="contents">
      <div
        data-ptr-indicator
        class="pointer-events-none fixed inset-x-0 top-[env(safe-area-inset-top)] z-40 -mt-9 flex justify-center opacity-0"
        aria-hidden="true"
      >
        <span
          data-ptr-spinner
          class="mt-2 flex size-8 items-center justify-center rounded-full border border-base-300 bg-base-100 text-base-content/70 shadow-sm"
        >
          <.icon name="hero-arrow-path" class="size-4" />
        </span>
      </div>
    </div>
    """
  end

  attr :type, :atom, required: true, values: [:sleep, :breastfeeding]
  attr :edit_start?, :boolean, default: false

  defp timer_nudges(assigns) do
    ~H"""
    <div id={"#{@type}-nudges"} class="mt-2 flex items-center gap-2">
      <span class="shrink-0 text-xs opacity-80">Started earlier?</span>
      <div class="grid flex-1 grid-cols-4 gap-1.5">
        <.button
          :for={m <- nudge_minutes()}
          type="button"
          size="xs"
          phx-click="nudge_start"
          phx-value-type={@type}
          phx-value-by={m}
        >
          {m}m
        </.button>
        <.button
          :if={@edit_start?}
          type="button"
          size="xs"
          phx-click="open_sheet"
          phx-value-kind="sleep_start"
          aria-label="Edit start time"
        >
          <.icon name="hero-pencil-square" class="size-3.5" />
        </.button>
      </div>
    </div>
    """
  end

  attr :type, :atom, required: true, values: [:feeding, :diaper, :sleep, :breastfeeding]
  attr :index, :integer, required: true, doc: "position in the child's Home order"
  attr :summary, :map, required: true
  attr :outlook, :map, required: true
  attr :current_child, :map, required: true
  attr :unit_system, :atom, required: true
  attr :can_write, :boolean, required: true
  attr :simple?, :boolean, default: false, doc: "simple mode: log the bottle with just an amount"

  # One at-a-glance card with its log buttons. Home renders these in the order
  # of the child's `tracked_types`, which is how caregivers arrange Home.
  defp glance(%{type: :feeding} = assigns) do
    ~H"""
    <div id="glance-feed">
      <.glance_card
        index={@index}
        emoji="🍼"
        label="Feeding"
        category="feed"
        tone={if @simple?, do: "base", else: feed_tone(@outlook)}
        value={
          if @simple?,
            do: simple_feed_value(@summary.last_feeding),
            else: feed_value(@summary.last_feeding, @outlook)
        }
        sub={
          if @simple?,
            do: simple_feed_sub(@summary.last_feeding, @current_child),
            else: feed_sub(@summary.last_feeding, @outlook, @unit_system)
        }
        status={if @simple?, do: nil, else: feed_status(@summary.last_feeding, @outlook)}
        today={if @simple?, do: nil, else: feed_today(@summary.today, @unit_system)}
      >
        <:actions :if={@can_write or @simple?}>
          <.button
            id="log-bottle"
            type="button"
            variant="info"
            phx-click="open_sheet"
            phx-value-kind={if @simple?, do: "bottle_simple", else: "bottle"}
            class="w-full"
          >
            <.icon name="hero-beaker" class="size-5" /> Log a bottle
          </.button>
        </:actions>
      </.glance_card>
    </div>
    """
  end

  defp glance(%{type: :diaper} = assigns) do
    ~H"""
    <div id="glance-diaper">
      <.glance_card
        index={@index}
        emoji={last_diaper_emoji(@summary.last_diaper)}
        label="Diaper"
        category="diaper"
        tone={if @simple?, do: "base", else: diaper_tone(@outlook)}
        value={relative_time(time_of(@summary.last_diaper))}
        sub={
          if @simple?,
            do: simple_diaper_sub(@summary.last_diaper, @current_child),
            else: diaper_sub(@summary.last_diaper, @summary.last_poo)
        }
        status={if @simple?, do: nil, else: diaper_status(@outlook)}
        today={if @simple?, do: nil, else: diaper_today(@summary.today)}
      >
        <:actions :if={@can_write or @simple?}>
          <div
            id="log-diaper"
            class={["grid gap-2", if(@simple?, do: "grid-cols-2", else: "grid-cols-3")]}
          >
            <.action_btn
              :for={{emoji, value, label} <- diaper_buttons(@simple?)}
              kind={"diaper_#{value}"}
              label={label}
              emoji={emoji}
              color_class={diaper_color_class(value)}
              large={@simple?}
            />
          </div>
        </:actions>
      </.glance_card>
    </div>
    """
  end

  defp glance(%{type: :sleep} = assigns) do
    ~H"""
    <div id="glance-sleep">
      <.glance_card
        index={@index}
        timer={Log.running(@summary, :sleep)}
        emoji={sleep_emoji(@summary)}
        snooze={sleeping?(@summary)}
        label={sleep_label(@summary)}
        category="sleep"
        tone={sleep_tone(@summary, @outlook)}
        value={sleep_value(@summary, @outlook)}
        sub={sleep_sub(@summary, @outlook, @current_child)}
        status={sleep_status(@summary, @outlook)}
        today={"#{format_duration(@summary.today.sleep_seconds)} slept today"}
      >
        <:actions :if={@can_write}>
          <%= if sleeping?(@summary) do %>
            <.button
              id="stop-sleep"
              type="button"
              variant="primary"
              phx-click="request_stop"
              phx-value-id={Log.running(@summary, :sleep).id}
              class="w-full"
            >
              <.icon name="hero-stop" class="size-5" /> Stop
            </.button>
            <.timer_nudges type={:sleep} edit_start? />
          <% else %>
            <.button
              id="log-sleep"
              variant="primary"
              phx-click="start_sleep"
              data-splash-lock
              class="w-full"
            >
              <.icon name="hero-moon" class="size-5" /> Start sleep
            </.button>
          <% end %>
        </:actions>
      </.glance_card>
    </div>
    """
  end

  defp glance(%{type: :breastfeeding} = assigns) do
    ~H"""
    <div id="glance-breastfeeding">
      <.glance_card
        index={@index}
        timer={Log.running(@summary, :breastfeeding)}
        emoji="🤱"
        label="Breastfeeding"
        category="feed"
        value={breastfeeding_value(@summary.last_breastfeeding)}
        sub={breastfeeding_sub(@summary.last_breastfeeding)}
        today={breastfeeding_today(@summary.today)}
      >
        <:actions :if={@can_write}>
          <%= if Log.running(@summary, :breastfeeding) do %>
            <.button
              id="stop-breastfeeding"
              type="button"
              variant="primary"
              phx-click="request_breastfeeding_stop"
              class="w-full"
            >
              <.icon name="hero-stop" class="size-5" /> Stop
            </.button>
            <.timer_nudges type={:breastfeeding} />
          <% else %>
            <.button
              id="start-breastfeeding"
              variant="primary"
              phx-click="start_breastfeeding"
              data-splash-lock
              class="w-full"
            >
              <.icon name="hero-heart" class="size-5" /> Start breastfeeding
            </.button>
          <% end %>
        </:actions>
      </.glance_card>
    </div>
    """
  end

  attr :kind, :string, required: true
  attr :label, :string, required: true
  attr :emoji, :string, required: true
  attr :color_class, :string, required: true
  attr :large, :boolean, default: false

  defp action_btn(assigns) do
    ~H"""
    <.button
      type="button"
      phx-click="quick"
      phx-value-kind={@kind}
      data-splash-lock
      class={["gap-1.5 px-1", @color_class]}
    >
      <span class="whitespace-nowrap text-xl leading-none" aria-hidden="true">{@emoji}</span>
      <span class={["font-bold", if(@large, do: "text-lg", else: "text-sm")]}>{@label}</span>
    </.button>
    """
  end

  attr :take_back, :map, default: nil, doc: "the simple member's offer, or nil"

  # What a simple member just logged, in plain words, with a big "Undo" for a
  # while. Once taken back it only says "Undone", for a moment.
  defp take_back_toast(assigns) do
    ~H"""
    <div
      :if={@take_back}
      id={"take-back-toast-#{@take_back.ref}"}
      role="status"
      class="pointer-events-none fixed inset-x-0 bottom-[calc(env(safe-area-inset-bottom)+1.5rem)] z-40 flex justify-center px-4"
    >
      <div class="undo-toast pointer-events-auto relative flex max-w-md items-center gap-4 overflow-hidden rounded-3xl bg-neutral py-3 pl-6 pr-3 text-neutral-content shadow-lg">
        <span id="take-back-label" class="text-lg font-bold">{@take_back.label}</span>
        <.button
          :if={@take_back.entry}
          id="take-back"
          type="button"
          variant="primary"
          phx-click="take_back"
          class="shrink-0"
        >
          Undo
        </.button>
        <span
          :if={@take_back.entry}
          class="undo-toast-timer absolute inset-x-0 bottom-0 h-1 bg-primary"
          style={"animation-duration: #{take_back_ms()}ms"}
          aria-hidden="true"
        ></span>
      </div>
    </div>
    """
  end

  defp take_back_ms, do: @take_back_ms

  # Each diaper kind gets its own fixed, literal color (see the
  # --color-diaper-* vars in app.css) instead of one shared variant, so the
  # three buttons are distinguishable by color alone, not just by emoji/label.
  defp diaper_color_class("pee"), do: "btn-diaper-pee"
  defp diaper_color_class("poo"), do: "btn-diaper-poo"
  defp diaper_color_class("mixed"), do: "btn-diaper-mixed"

  attr :kind, :atom, required: true
  attr :form, :any, default: nil
  attr :unit_system, :atom, required: true
  attr :photo_upload, :any, required: true
  attr :vitamin_d_prompt?, :boolean, default: false
  attr :tracked_types, :list, default: [:feeding, :diaper, :sleep]
  attr :devices, :list, default: [], doc: "the family's room sensors, for the Customize sheet"
  attr :timezone, :string, required: true

  defp sheet(assigns) do
    assigns =
      assigns
      |> assign(:unit, Units.unit_label(:volume, assigns.unit_system))
      |> assign(:controls, sheet_controls(assigns.timezone))

    ~H"""
    <.sheet_frame id="quick-sheet" close="close_sheet" label={sheet_label(@kind)} modal_back>
      <%= case @kind do %>
        <% :earlier -> %>
          <h3 class="font-semibold text-lg mb-1">Log from earlier</h3>
          <p class="text-sm opacity-70 mb-4">What do you want to add?</p>
          <div class="space-y-2">
            <.button
              :if={:sleep in @tracked_types}
              type="button"
              variant="primary"
              size="lg"
              phx-click="open_sheet"
              phx-value-kind="sleep_past"
              class="w-full h-16 justify-start gap-3 text-base"
            >
              <.icon name="hero-moon" class="size-6" /> Sleep
            </.button>
            <.button
              :if={:breastfeeding in @tracked_types}
              type="button"
              variant="primary"
              size="lg"
              phx-click="start_breastfeeding"
              class="w-full h-16 justify-start gap-3 text-base"
            >
              <.icon name="hero-heart" class="size-6" /> Breastfeeding
            </.button>
            <.button
              :if={:feeding in @tracked_types}
              type="button"
              variant="info"
              size="lg"
              phx-click="open_sheet"
              phx-value-kind="bottle"
              class="w-full h-16 justify-start gap-3 text-base"
            >
              <.icon name="hero-beaker" class="size-6" /> Bottle
            </.button>
            <.button
              :if={:diaper in @tracked_types}
              type="button"
              variant="accent"
              size="lg"
              phx-click="open_sheet"
              phx-value-kind="diaper_past"
              class="w-full h-16 justify-start gap-3 text-base"
            >
              <span class="text-2xl leading-none" aria-hidden="true">🧷</span> Diaper
            </.button>
          </div>
          <div class="pt-4">
            <.button
              type="button"
              variant="ghost"
              class="w-full"
              phx-click={close_sheet("close_sheet", "quick-sheet")}
            >
              Cancel
            </.button>
          </div>
        <% :layout -> %>
          <h3 class="font-semibold text-lg mb-1">Customize Today</h3>
          <p class="text-sm opacity-70 mb-4">
            Choose what to track and put it in the order you like. Everyone caring for this child
            sees the same cards. Hidden entries stay in the full log and reports. Room
            sensors you tick show up below the cards, on your Today only.
          </p>
          <.form
            for={@form}
            id="layout-form"
            phx-hook="LayoutReorder"
            phx-submit="save_layout"
            class="space-y-2"
          >
            <input type="hidden" name="layout[tracked_types][]" value="" />
            <% order = List.wrap(@form.params["order"]) %>
            <div
              :for={{type, i} <- Enum.with_index(order)}
              id={"layout-row-#{type}"}
              data-reorder-row
              class="flex items-center gap-1 rounded-box bg-base-200/60 pr-2"
            >
              <%!-- Drag handle for the `LayoutReorder` hook; the buttons at the
                   right are the accessible way to do the same thing. --%>
              <span
                data-drag-handle
                aria-hidden="true"
                class="grid h-12 w-9 shrink-0 cursor-grab touch-none place-items-center text-base-content/40"
              >
                <.icon name="hero-bars-3" class="size-5" />
              </span>
              <input type="hidden" name="layout[order][]" value={type} />
              <label class="flex min-h-12 flex-1 items-center gap-3 py-3 pr-3">
                <input
                  type="checkbox"
                  id={"layout-#{type}"}
                  name="layout[tracked_types][]"
                  value={type}
                  checked={type in List.wrap(@form.params["tracked_types"])}
                  class="checkbox checkbox-sm"
                />
                <span class="font-medium">{tracker_label(type)}</span>
              </label>
              <.button
                id={"layout-up-#{type}"}
                type="button"
                variant="ghost"
                size="sm"
                class="btn-circle"
                data-move="up"
                disabled={i == 0}
                aria-label={"Move #{tracker_label(type)} up"}
              >
                <.icon name="hero-chevron-up" class="size-5" />
              </.button>
              <.button
                id={"layout-down-#{type}"}
                type="button"
                variant="ghost"
                size="sm"
                class="btn-circle"
                data-move="down"
                disabled={i == length(order) - 1}
                aria-label={"Move #{tracker_label(type)} down"}
              >
                <.icon name="hero-chevron-down" class="size-5" />
              </.button>
            </div>
            <div :if={@devices != []} id="layout-devices" class="pt-2">
              <input type="hidden" name="layout[devices][]" value="" />
              <h4 class="mb-1 text-sm font-semibold">Room sensors</h4>
              <label
                :for={device <- @devices}
                id={"layout-device-row-#{device.id}"}
                class="flex min-h-12 items-center gap-3 rounded-box bg-base-200/60 px-3 py-3"
              >
                <input
                  type="checkbox"
                  id={"layout-device-#{device.id}"}
                  name="layout[devices][]"
                  value={device.id}
                  checked={to_string(device.id) in List.wrap(@form.params["devices"])}
                  class="checkbox checkbox-sm"
                />
                <span class="font-medium">{Trygg.Devices.Device.label(device)}</span>
              </label>
            </div>
            <p
              :for={{msg, _opts} <- @form[:tracked_types].errors}
              id="layout-error"
              class="flex gap-2 items-center text-sm text-error"
            >
              <.icon name="hero-exclamation-circle" class="size-5" />
              {msg}
            </p>
            <.sheet_buttons save="Save" />
          </.form>
        <% :bottle -> %>
          <h3 class="font-semibold text-lg mb-3">Log a bottle</h3>
          <.form
            for={@form}
            id="bottle-form"
            phx-change="sheet_change"
            phx-submit="save_sheet"
            class="space-y-4"
            {@controls}
          >
            <.amount_stepper amount={@form.params["amount"]} unit_system={@unit_system} unit={@unit} />

            <select
              name="entry[bottle_contents]"
              aria-label="What was in the bottle"
              class="select w-full"
            >
              <option
                :for={c <- Entry.bottle_contents()}
                value={c}
                selected={c == @form.params["bottle_contents"]}
              >
                {contents_option_label(c)}
              </option>
            </select>

            <.vitamin_d_field
              :if={@vitamin_d_prompt?}
              checked={@form.params["vitamin_d"] == "true"}
            />

            <.time_field form={@form} field={:at} label="When" />

            <input
              type="text"
              name="entry[note]"
              data-client-owned
              value={@form.params["note"]}
              placeholder="Note (optional)"
              aria-label="Note"
              class="input w-full"
            />

            <.photo_field upload={@photo_upload} />

            <.sheet_buttons save="Save" uploading?={photo_uploading?(@photo_upload)} />
          </.form>
        <% :bottle_simple -> %>
          <h3 class="font-semibold text-lg mb-3">Log a bottle</h3>
          <.form
            for={@form}
            id="simple-bottle-form"
            phx-change="sheet_change"
            phx-submit="save_bottle_now"
            class="space-y-4"
            {@controls}
          >
            <input
              type="hidden"
              name="entry[bottle_contents]"
              value={@form.params["bottle_contents"]}
            />
            <.amount_stepper amount={@form.params["amount"]} unit_system={@unit_system} unit={@unit} />
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
            {@controls}
          >
            <.input field={@form[:ended_at]} type="datetime-local" label="Woke up at" />
            <.note_field form={@form} />
            <.photo_field upload={@photo_upload} />
            <.sheet_buttons save="Save sleep" uploading?={photo_uploading?(@photo_upload)} />
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
            {@controls}
          >
            <.time_field form={@form} field={:started_at} label="Fell asleep" />
            <.time_field form={@form} field={:ended_at} label="Woke up" />
            <.note_field form={@form} />
            <.photo_field upload={@photo_upload} />
            <.sheet_buttons save="Add sleep" uploading?={photo_uploading?(@photo_upload)} />
          </.form>
        <% :breastfeeding_stop -> %>
          <h3 class="font-semibold text-lg mb-3">Finished feeding</h3>
          <.form
            for={@form}
            id="breastfeeding-form"
            phx-change="sheet_change"
            phx-submit="save_breastfeeding"
            class="space-y-4"
            {@controls}
          >
            <.input field={@form[:ended_at]} type="datetime-local" label="Finished at" />
            <.breastfeeding_pattern_fieldset form={@form} name="breastfeeding" />
            <.note_field form={@form} />
            <.photo_field upload={@photo_upload} />
            <.sheet_buttons
              save="Save breastfeeding"
              uploading?={photo_uploading?(@photo_upload)}
            />
          </.form>
        <% :diaper_past -> %>
          <h3 class="font-semibold text-lg mb-3">Add a diaper from earlier</h3>
          <.form
            for={@form}
            id="diaper-form"
            phx-change="sheet_change"
            phx-submit="save_diaper"
            class="space-y-4"
            {@controls}
          >
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
            <.time_field form={@form} field={:started_at} label="When" />
            <.input
              field={@form[:note]}
              type="text"
              label="Note"
              placeholder="Anything to remember? (optional)"
            />
            <.photo_field upload={@photo_upload} />
            <.sheet_buttons save="Add diaper" uploading?={photo_uploading?(@photo_upload)} />
          </.form>
      <% end %>
    </.sheet_frame>
    """
  end

  attr :amount, :any, required: true
  attr :unit_system, :atom, required: true
  attr :unit, :string, required: true

  # The bottle sheet's amount control: a big editable number with ± and quick
  # "+N" chips, driven client-side by `SheetControls` (`data-bump`,
  # `data-amount-reset`) so it's instant on a slow connection.
  defp amount_stepper(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-center gap-4">
        <.button
          type="button"
          variant="outline"
          class="btn-circle"
          data-bump={-fine_step(@unit_system)}
          aria-label={"Decrease by #{trim(fine_step(@unit_system) * 1.0)} #{@unit}"}
        >
          <.icon name="hero-minus" class="size-4" />
        </.button>

        <div class="flex items-baseline gap-1">
          <input
            type="number"
            inputmode="decimal"
            step="any"
            min="0"
            name="entry[amount]"
            id="bottle-amount"
            data-client-owned
            value={@amount}
            aria-label={"Amount in #{@unit}"}
            class="w-24 rounded-field bg-transparent py-1 text-center text-3xl font-bold tracking-tight tabular-nums outline-none focus-visible:bg-base-200 focus-visible:ring-2 focus-visible:ring-primary [appearance:textfield] [&::-webkit-outer-spin-button]:appearance-none [&::-webkit-inner-spin-button]:appearance-none"
          />
          <span class="text-base font-normal opacity-70">{@unit}</span>
        </div>

        <.button
          type="button"
          variant="outline"
          class="btn-circle"
          data-bump={fine_step(@unit_system)}
          aria-label={"Increase by #{trim(fine_step(@unit_system) * 1.0)} #{@unit}"}
        >
          <.icon name="hero-plus" class="size-4" />
        </.button>
      </div>

      <div class="flex gap-2 justify-center mt-2 flex-wrap">
        <.button
          :for={step <- preset_steps(@unit_system)}
          type="button"
          variant="outline"
          size="sm"
          data-bump={step}
        >
          +{step}
        </.button>
        <.button
          type="button"
          variant="ghost"
          size="sm"
          id="bottle-reset"
          data-amount-reset
        >
          Reset
        </.button>
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
          size="sm"
          data-note-text={n}
        >
          {n}
        </.button>
      </div>
      <.input
        field={@form[:note]}
        type="text"
        label="Note"
        placeholder="Anything to remember? (optional)"
        data-client-owned
      />
    </div>
    """
  end

  attr :form, :any, required: true
  attr :field, :atom, required: true
  attr :label, :string, required: true

  # One-tap "Now / 5m ago / 15m ago / …" chips above a datetime-local input,
  # shared by every "log from earlier" sheet so backdating feels the same
  # everywhere: sleep, bottle, diaper.
  defp time_field(assigns) do
    ~H"""
    <div>
      <div class="flex flex-wrap gap-2 mb-2">
        <.button
          :for={{label, mins} <- time_offsets()}
          type="button"
          variant="outline"
          size="sm"
          data-nudge-field={@field}
          data-nudge-by={mins}
        >
          {label}
        </.button>
      </div>
      <.input field={@form[@field]} type="datetime-local" label={@label} data-client-owned />
    </div>
    """
  end

  attr :save, :string, required: true
  attr :uploading?, :boolean, default: false

  defp sheet_buttons(assigns) do
    ~H"""
    <div class="flex gap-2 pt-1">
      <.save_button label={@save} uploading?={@uploading?} class="flex-1" />
      <.button type="button" variant="ghost" phx-click={close_sheet("close_sheet", "quick-sheet")}>
        Cancel
      </.button>
    </div>
    """
  end

  ## Presentation helpers ----------------------------------------------

  # What `SheetControls` (assets/js/hooks/sheet_controls.js) needs to run the
  # sheet's chips and steppers without the server: the child's time zone and the
  # server's clock, so "now" is the instant the server will check against.
  defp sheet_controls(timezone) do
    [
      "phx-hook": "SheetControls",
      "data-timezone": timezone,
      "data-server-now": DateTime.to_unix(DateTime.utc_now(), :millisecond)
    ]
  end

  defp simple_types, do: @simple_types

  # Simple mode's diaper is wet or dirty: no "mixed" to choose.
  defp diaper_buttons(true),
    do: Enum.reject(diaper_choices(), fn {_, kind, _} -> kind == "mixed" end)

  defp diaper_buttons(false), do: diaper_choices()

  defp nudge_minutes, do: @nudge_minutes
  defp note_suggestions, do: @note_suggestions

  # Emoji for the "Last diaper" card — the most recent diaper's kind, or a
  # neutral pin when nothing's been logged yet. `diaper_choices/0` /
  # `diaper_emoji/1` come from TryggWeb.LogComponents so every surface agrees.
  defp last_diaper_emoji(%Entry{data: %{"kind" => k}}), do: diaper_emoji(k)
  defp last_diaper_emoji(_), do: diaper_emoji(nil)

  # {label, minutes-from-now} one-tap chips for back-dating any "log from
  # earlier" time field (sleep, bottle, diaper) — kept in one list so every
  # sheet offers the same quick options.
  defp time_offsets,
    do: [{"Now", 0}, {"5m ago", -5}, {"15m ago", -15}, {"30m ago", -30}, {"1h ago", -60}]

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

  # Offer the vitamin D tick on a bottle only while the child's reminder is on
  # and today's drop hasn't been logged yet.
  defp vitamin_d_prompt?(%Child{vitamin_d_reminder: true}, %{vitamin_d_given_today?: false}),
    do: true

  defp vitamin_d_prompt?(_child, _summary), do: false

  defp feed_time(%Entry{started_at: at}), do: at

  defp time_of(nil), do: nil
  defp time_of(%Entry{started_at: at}), do: at

  defp breastfeeding_sub(nil), do: "No session yet"
  defp breastfeeding_sub(%Entry{ended_at: nil}), do: "In progress"

  defp breastfeeding_sub(%Entry{data: %{"pattern" => pattern}}),
    do: Entry.breastfeeding_pattern_label(pattern)

  defp breastfeeding_sub(_), do: "Last session"

  defp breastfeeding_value(%Entry{ended_at: nil} = entry),
    do: format_duration(Entry.duration_seconds(entry))

  defp breastfeeding_value(entry), do: relative_time(time_of(entry))

  defp breastfeeding_today(%{breastfeeding_sessions: count, breastfeeding_seconds: seconds}) do
    "#{count} #{plural(count, "session")} · #{format_duration(seconds)} today · not bottle feeds"
  end

  # Feed card. The primary `value` is plain time since the last feed — the
  # single most-checked fact — in the card's biggest text; the next-feed
  # estimate demotes to the neutral `sub` line. The tone-coloured `status`
  # only appears when something needs attention (a cluster in progress, or a
  # feed running later than the baby's own rhythm) — the sub line alone
  # doesn't carry enough weight to flag that on its own. The estimate comes
  # from their pattern, not a schedule, so the copy says "usual", never
  # "overdue" or "missed".
  @late_seconds -30 * 60

  # Simple mode's feed card says only when the last feed was: no cluster
  # call-out, no "next feed" estimate, no running total.
  defp simple_feed_value(nil), do: "No feeds yet"
  defp simple_feed_value(%Entry{} = e), do: relative_time(feed_time(e))

  defp feed_value(nil, _outlook), do: "No feeds yet"

  defp feed_value(%Entry{} = e, outlook) do
    if match?(%{active?: true}, outlook.cluster) do
      "#{outlook.cluster.count} feeds in 2h"
    else
      relative_time(feed_time(e))
    end
  end

  defp feed_sub(nil, _outlook, _units), do: nil

  defp feed_sub(%Entry{} = e, outlook, units) do
    cond do
      match?(%{active?: true}, outlook.cluster) ->
        "Last fed #{relative_time(feed_time(e))}"

      next = outlook.next_feed ->
        "Next ~#{next.label} · #{due_label(next.in_seconds)}"

      true ->
        entry_title(e, units)
    end
  end

  defp feed_status(nil, _outlook), do: nil

  defp feed_status(%Entry{}, outlook) do
    cond do
      match?(%{active?: true}, outlook.cluster) -> "cluster feeding?"
      next = outlook.next_feed -> due_status(next.in_seconds)
      true -> nil
    end
  end

  defp due_status(s) when s <= @late_seconds, do: "#{format_duration(-s)} later than usual"
  defp due_status(_), do: nil

  defp feed_tone(%{next_feed: %{in_seconds: s}}) when is_integer(s) and s <= @late_seconds,
    do: "warning"

  defp feed_tone(_), do: "base"

  defp due_label(seconds) when seconds < -60, do: "#{format_duration(-seconds)} past usual"
  defp due_label(seconds) when seconds < 60, do: "about now"
  defp due_label(seconds), do: "in #{format_duration(seconds)}"

  defp feed_today(%{feedings: 0}, _units), do: "none today"

  defp feed_today(%{feedings: n, volume_ml: ml}, units),
    do: "#{n} #{plural(n, "feed")} · #{Units.format(ml, :volume, units)} today"

  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "s"

  # The value already says when the last diaper was, so the sub line adds what
  # it was and, when that wasn't a poo, how long ago the last poo was.
  # Simple mode's diaper card says what the last one was and nothing more: no
  # "no poo yet" / time since the last poo, no counts.
  # Simple mode pairs "2h 5m ago" with the clock time, so there's no sum to do
  # and it can be read out to a parent as is.
  defp simple_feed_sub(%Entry{} = e, child), do: "at #{Child.local_clock(child, feed_time(e))}"
  defp simple_feed_sub(nil, _child), do: nil

  defp simple_diaper_sub(%Entry{data: %{"kind" => kind}} = e, child) when is_binary(kind),
    do: "#{String.capitalize(kind)} · at #{Child.local_clock(child, e.started_at)}"

  defp simple_diaper_sub(%Entry{} = e, child), do: "At #{Child.local_clock(child, e.started_at)}"
  defp simple_diaper_sub(nil, _child), do: "none yet"

  defp diaper_sub(nil, _last_poo), do: "none yet"

  defp diaper_sub(%Entry{data: %{"kind" => kind}}, _last_poo) when kind in ["poo", "mixed"],
    do: String.capitalize(kind)

  defp diaper_sub(%Entry{data: %{"kind" => kind}}, nil),
    do: "#{String.capitalize(kind)} · no poo yet"

  defp diaper_sub(%Entry{data: %{"kind" => kind}}, %Entry{} = last_poo),
    do: "#{String.capitalize(kind)} · #{diaper_emoji("poo")} #{poo_ago(last_poo.started_at)}"

  defp diaper_sub(_, _), do: nil

  # Whole hours, since "5h 12m" is more precision than "when was the last poo"
  # needs; days once it's been a couple.
  defp poo_ago(%DateTime{} = at) do
    hours = div(DateTime.diff(DateTime.utc_now(), at, :second), 3600)

    cond do
      hours < 1 -> "<1h ago"
      hours < 48 -> "#{hours}h ago"
      true -> "#{div(hours, 24)}d ago"
    end
  end

  defp diaper_today(%{diapers: 0}), do: "none today"

  defp diaper_today(%{diapers: n, diapers_wet: wet, diapers_dirty: dirty}),
    do:
      "#{n} #{plural(n, "diaper")} · #{diaper_emoji("pee")} #{wet} · #{diaper_emoji("poo")} #{dirty}"

  defp diaper_status(%{diapers: %{flags: flags} = diapers}) do
    cond do
      :no_wet_6h in flags -> "no wet diaper in #{div(diapers.dry_seconds || 0, 3600)}h"
      :low_wet_pace in flags or :low_wet_day in flags -> "fewer wet diapers than usual"
      true -> nil
    end
  end

  defp diaper_status(_), do: nil

  defp diaper_tone(%{diapers: %{flags: flags}}) when flags != [], do: "warning"
  defp diaper_tone(_), do: "base"

  # Sleep card. The label carries the state ("Asleep" / "Awake") so the value
  # can be a plain duration instead of an ambiguous "1h 41m ago". Once a next
  # nap can be predicted, that becomes the primary `value` (mirroring the
  # feed card) and the awake duration moves down to `sub`.
  defp sleeping?(summary), do: not is_nil(Log.running(summary, :sleep))

  defp woke_at(%{last_sleep: %Entry{ended_at: %DateTime{} = at}}), do: at
  defp woke_at(%{last_sleep: %Entry{started_at: at}}), do: at
  defp woke_at(_), do: nil

  defp sleep_emoji(summary), do: if(sleeping?(summary), do: "😴", else: "☀️")

  defp sleep_label(summary) do
    cond do
      sleeping?(summary) -> "Asleep"
      woke_at(summary) -> "Awake"
      true -> "Sleep"
    end
  end

  defp sleep_value(summary, outlook) do
    cond do
      e = Log.running(summary, :sleep) ->
        format_duration(Entry.duration_seconds(e))

      nap = awake_next_nap(outlook) ->
        "Nap · #{due_label(nap.in_seconds)}"

      woke = woke_at(summary) ->
        format_duration(DateTime.diff(now(), woke, :second))

      true ->
        "—"
    end
  end

  defp sleep_sub(summary, outlook, child) do
    cond do
      e = Log.running(summary, :sleep) ->
        "since #{Child.local_clock(child, e.started_at)}"

      nap = awake_next_nap(outlook) ->
        case woke_at(summary) do
          %DateTime{} = woke ->
            "~#{nap.label} · awake #{format_duration(DateTime.diff(now(), woke, :second))}"

          nil ->
            "~#{nap.label}"
        end

      pressure = wake_pressure(outlook) ->
        "usually up #{format_duration(pressure.typical_seconds)}" <>
          if(pressure.source == :age_prior, do: " (for age)", else: "")

      woke = woke_at(summary) ->
        "woke at #{Child.local_clock(child, woke)}"

      true ->
        "no sleep logged yet"
    end
  end

  defp sleep_status(summary, outlook) do
    if sleeping?(summary) do
      nil
    else
      case wake_pressure(outlook) do
        %{state: :past} -> "past the usual nap window"
        %{state: :approaching} -> "nap window coming up"
        _ -> nil
      end
    end
  end

  defp sleep_tone(summary, outlook) do
    cond do
      sleeping?(summary) -> "success"
      match?(%{state: :past}, wake_pressure(outlook)) -> "warning"
      true -> "base"
    end
  end

  defp wake_pressure(%{prediction: %{state: :awake, wake_pressure: %{state: state} = p}})
       when not is_nil(state),
       do: p

  defp wake_pressure(_), do: nil

  defp trim(f) when is_float(f) do
    if f == Float.round(f), do: trunc(f), else: Float.round(f, 1)
  end

  defp visible_alerts(alerts, dismissed, child, filter) do
    Enum.filter(alerts, fn alert ->
      filter.(alert) and to_string(alert.id) not in dismissed and tracked_alert?(alert, child)
    end)
  end

  defp tracked_alert?(alert, child) do
    case Alerts.tracker(alert) do
      nil -> true
      type -> Child.tracks?(child, type)
    end
  end

  # Copy for the home weight-check banner. `never_measured?` means we're
  # anchored on the birth date, not a prior reading; `source` says whether the
  # cadence is the CDC schedule or this caregiver's own setting.
  defp weight_reminder_detail(%{never_measured?: true} = r) do
    "No weight logged yet. #{cadence_clause(r)}"
  end

  defp weight_reminder_detail(%{days_since: since} = r) do
    "Last weight was #{humanize_days(since)} ago. #{cadence_clause(r)}"
  end

  defp cadence_clause(%{source: :custom, interval_days: interval}) do
    "You asked to be reminded every #{humanize_days(interval)}."
  end

  defp cadence_clause(%{interval_days: interval}) do
    "The CDC well-child schedule suggests one about every #{humanize_days(interval)} at this age."
  end

  defp humanize_days(days) when days >= 60, do: "#{round(days / 30)} months"
  defp humanize_days(days) when days >= 14, do: "#{div(days + 3, 7)} weeks"
  defp humanize_days(1), do: "1 day"
  defp humanize_days(days), do: "#{days} days"
end
