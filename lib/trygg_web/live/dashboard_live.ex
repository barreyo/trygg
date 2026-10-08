defmodule TryggWeb.DashboardLive do
  use TryggWeb, :live_view

  alias Trygg.{Families, Growth, Log, Notices, Push, Reports}
  alias Trygg.Accounts.Scope
  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias Trygg.Reports.Alerts
  alias Trygg.Units
  alias TryggWeb.Loading

  @recent_limit 20
  @tick_ms 60_000
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
    end

    scope = socket.assigns.current_scope
    child = socket.assigns.current_child

    socket =
      socket
      |> assign(:unit_system, scope.user.unit_system)
      |> assign(:can_write, child.role in [:owner, :caregiver])
      |> assign(:sheet, nil)
      |> assign(:sheet_form, nil)
      |> assign(:editing, nil)
      |> assign(:edit_vitamin_d?, false)
      |> assign(:edit_form, nil)
      |> assign(:now_tick, System.system_time(:second))
      |> assign(:vapid_public_key, Push.vapid_public_key())
      |> assign(:dismissed_notices, MapSet.new())
      |> assign(summary: nil, outlook: nil, weight_reminder: nil, rhythm_center: nil)
      |> assign(:entries_empty?, false)
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
  def handle_info({:log, _action, _entry}, socket), do: {:noreply, refresh(socket)}

  def handle_info({:growth, _action, _measurement}, socket),
    do: {:noreply, refresh_summary(socket)}

  def handle_info({:child_updated, child}, socket) do
    {:noreply,
     socket
     |> assign(:current_child, %{child | role: socket.assigns.role})
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

  def handle_info(_msg, socket), do: {:noreply, socket}

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

        socket =
          socket
          |> assign(:role, role)
          |> assign(:can_write, can_write)
          |> assign(:current_child, child)
          |> assign(:current_scope, Scope.put_child(scope, child, role))

        if can_write do
          socket
        else
          assign(socket, editing: nil, edit_form: nil)
        end
    end
  end

  ## Sleep events -------------------------------------------------------

  @impl true
  def handle_event("start_sleep", _params, socket) do
    Log.start_timer(socket.assigns.current_scope, socket.assigns.current_child, :sleep)
    {:noreply, socket}
  end

  def handle_event("nudge_start", %{"by" => by}, socket) do
    minutes = String.to_integer(by)

    socket =
      case running_sleep(socket.assigns) do
        %Entry{} = nap ->
          new_start = DateTime.add(nap.started_at, minutes * 60, :second)

          cond do
            DateTime.compare(new_start, DateTime.utc_now()) == :gt ->
              put_flash(socket, :error, "That would put the start in the future.")

            DateTime.diff(DateTime.utc_now(), new_start, :second) > 86_400 ->
              put_flash(socket, :error, "That's more than a day back — use Edit for that.")

            true ->
              case Log.retime_entry(socket.assigns.current_scope, nap, %{
                     "started_at" => new_start
                   }) do
                {:ok, _} -> socket
                {:error, _} -> put_flash(socket, :error, "Couldn't change the start time.")
              end
          end

        nil ->
          socket
      end

    {:noreply, socket}
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
    form = to_form(%{"ended_at" => Child.to_local_input(child, now()), "note" => ""}, as: :sleep)
    {:noreply, socket |> clear_photo_upload() |> assign(sheet: :sleep_stop, sheet_form: form)}
  end

  def handle_event("sheet_change", %{"sleep" => params}, socket) do
    {:noreply, assign(socket, :sheet_form, to_form(params, as: :sleep))}
  end

  def handle_event("sheet_change", %{"entry" => params}, socket) do
    {:noreply, assign(socket, :sheet_form, to_form(params, as: :entry))}
  end

  # Backs every quick time chip in the "Log from earlier" sheets (sleep,
  # bottle, diaper) — `field` is whichever datetime-local input the chip row
  # sits above, so one handler covers all of them consistently.
  def handle_event("nudge_time", %{"field" => field, "by" => by}, socket) do
    at = DateTime.add(now(), String.to_integer(by) * 60, :second)
    local = Child.to_local_input(socket.assigns.current_child, at)

    params =
      socket
      |> current_sheet_params()
      |> Map.put(field, local)

    {:noreply,
     assign(socket, :sheet_form, to_form(params, as: sheet_form_as(socket.assigns.sheet)))}
  end

  def handle_event("set_note", %{"text" => text}, socket) do
    params = Map.put(current_sheet_params(socket), "note", text)
    {:noreply, assign(socket, :sheet_form, to_form(params, as: :sleep))}
  end

  def handle_event("save_sleep", %{"sleep" => params}, socket) do
    {:noreply, save_sleep(socket, socket.assigns.sheet, params)}
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

  def handle_event("open_sheet", %{"kind" => "sleep_start"}, socket) do
    case running_sleep(socket.assigns) do
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
    {:ok, _} = Log.delete_entry(socket.assigns.current_scope, socket.assigns.editing)
    {:noreply, socket |> assign(editing: nil, edit_form: nil) |> put_flash(:info, "Deleted.")}
  end

  def handle_event("bump_amount", %{"by" => by}, socket) do
    step = parse_number(by) || 0
    current = parse_number(current_sheet_params(socket)["amount"]) || 0
    new_amount = trim(max(current + step, 0) * 1.0)
    params = Map.put(current_sheet_params(socket), "amount", new_amount)
    {:noreply, assign(socket, :sheet_form, to_form(params, as: :entry))}
  end

  def handle_event("reset_amount", _params, socket) do
    params = Map.put(current_sheet_params(socket), "amount", trim(0.0))
    {:noreply, assign(socket, :sheet_form, to_form(params, as: :entry))}
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

  defp settle_diaper(socket, {:ok, _}),
    do: socket |> assign(sheet: nil, sheet_form: nil) |> put_flash(:info, "Added that diaper.")

  defp settle_diaper(socket, {:error, :future}),
    do: put_flash(socket, :error, "That's in the future — pick an earlier time.")

  defp settle_diaper(socket, :error),
    do: put_flash(socket, :error, "That date and time didn't look right.")

  defp settle_diaper(socket, {:error, _}),
    do: put_flash(socket, :error, "Hmm, that didn't save — try again.")

  defp settle_feed(socket, {:ok, _}),
    do: socket |> assign(sheet: nil, sheet_form: nil) |> put_flash(:info, "Saved.")

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
           %Entry{} = nap <- running_sleep(socket.assigns) do
        # a datetime-local field is minute-granular; if the chosen end lands on
        # or before the start (e.g. stopping a nap that began seconds ago), the
        # tap means "now".
        ended = if DateTime.after?(ended, nap.started_at), do: ended, else: now()

        Log.stop_timer(
          scope,
          nap,
          Map.merge(
            %{"ended_at" => ended, "note" => blank(params["note"])},
            consume_photo(socket)
          )
        )
      end

    settle(socket, result, "Sleep saved — sweet dreams.")
  end

  defp save_sleep(socket, :sleep_start, params) do
    scope = socket.assigns.current_scope

    result =
      with {:ok, started} <-
             Child.from_local_input(socket.assigns.current_child, params["started_at"] || ""),
           :ok <- not_future(started),
           %Entry{} = nap <- running_sleep(socket.assigns) do
        Log.retime_entry(scope, nap, %{"started_at" => started})
      end

    settle(socket, result, "Updated the start time.")
  end

  defp save_sleep(socket, :sleep_past, params) do
    child = socket.assigns.current_child

    result =
      with {:ok, started} <- Child.from_local_input(child, params["started_at"] || ""),
           {:ok, ended} <- Child.from_local_input(child, params["ended_at"] || "") do
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

    settle(socket, result, "Added that sleep.")
  end

  defp settle(socket, {:ok, _}, msg),
    do: socket |> assign(sheet: nil, sheet_form: nil) |> put_flash(:info, msg)

  defp settle(socket, {:error, %Ecto.Changeset{}}, _msg),
    do: put_flash(socket, :error, "Their wake-up time needs to be after they fell asleep.")

  defp settle(socket, {:error, :future}, _msg),
    do: put_flash(socket, :error, "That's in the future — pick an earlier time.")

  defp settle(socket, nil, _msg),
    do: socket |> assign(sheet: nil) |> put_flash(:error, "There's no sleep to update right now.")

  defp settle(socket, :error, _msg),
    do: put_flash(socket, :error, "That date and time didn't look right.")

  ## Helpers ------------------------------------------------------------

  defp quick_log(socket, "diaper_" <> kind) do
    result =
      Log.create_entry(socket.assigns.current_scope, socket.assigns.current_child, :diaper, %{
        "data" => %{"kind" => kind}
      })

    case result do
      {:ok, _} -> put_flash(socket, :info, "Saved.")
      _ -> put_flash(socket, :error, "Hmm, that didn't save — try again.")
    end
  end

  defp consume_photo(socket), do: consume_photo(socket, socket.assigns.current_child)

  # Anything that changes before the first load lands just restarts it, so
  # the result that does land is never older than the change.
  defp refresh(%{assigns: %{loaded?: false}} = socket), do: load(socket)
  defp refresh(socket), do: socket |> refresh_summary() |> refresh_entries()

  defp fetch_home(scope, child) do
    %{
      status: fetch_status(scope, child),
      entries: recent_tracked(scope, child, @recent_limit)
    }
  end

  defp apply_home(socket, %{status: status, entries: entries}) do
    socket
    |> apply_status(status)
    |> apply_entries(entries)
  end

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
      e = running_sleep_entry(summary) ->
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
            %{id: e.id, started_at: DateTime.to_iso8601(e.started_at)}
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

  defp refresh_entries(socket) do
    scope = socket.assigns.current_scope
    child = socket.assigns.current_child
    apply_entries(socket, recent_tracked(scope, child, @recent_limit))
  end

  # Recent activity limited to what this child's Home tracks, so a hidden
  # tracker's old entries don't linger in the list.
  defp recent_tracked(scope, child, limit),
    do: Log.list_entries(scope, child, limit: limit, types: child.tracked_types)

  defp apply_entries(socket, entries) do
    socket
    |> assign(:entries_empty?, entries == [])
    |> stream(:entries, entries, reset: true)
  end

  defp running_sleep(%{summary: %{running: running}}),
    do: Enum.find(running, &(&1.type == :sleep))

  defp current_sheet_params(%{assigns: %{sheet_form: %{params: params}}}) when is_map(params),
    do: params

  defp current_sheet_params(_socket), do: %{}

  # The sleep sheets submit as `sleep` params, everything else as `entry`.
  defp sheet_form_as(sheet) when sheet in [:sleep_stop, :sleep_start, :sleep_past], do: :sleep
  defp sheet_form_as(_sheet), do: :entry

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

      <%!-- Pull-to-refresh: a standalone PWA has no native pull-to-refresh, so
           this inert sentinel's `PullToRefresh` hook drives the gesture on
           <main> and pushes `refresh`. --%>
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

      <%!-- Status and quick actions on the left, the recent log beside them
           once there is room (stacked on phones). --%>
      <Layouts.columns id="home-columns">
        <:left>
          <.loadable id="home-status" loaded={@loaded?} failed={@load_failed?}>
            <:skeleton><.home_status_skeleton can_write={@can_write} /></:skeleton>
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

            <%!-- Running sleep timer — Stop and start-time fixes live inside this card --%>
            <div :for={entry <- @summary.running} class="mb-6">
              <.timer_banner
                entry={entry}
                can_write={@can_write}
                on_stop="request_stop"
                since_label={Child.local_clock(@current_child, entry.started_at)}
              >
                <:controls :if={@can_write}>
                  <span class="text-xs opacity-70 mr-0.5">Started earlier?</span>
                  <.button
                    :for={m <- nudge_minutes()}
                    type="button"
                    size="xs"
                    phx-click="nudge_start"
                    phx-value-by={m}
                    class={timer_control_class()}
                  >
                    {m}m
                  </.button>
                  <.button
                    type="button"
                    size="xs"
                    phx-click="open_sheet"
                    phx-value-kind="sleep_start"
                    class={timer_control_class()}
                  >
                    <.icon name="hero-pencil-square" class="size-3.5" /> Edit
                  </.button>
                </:controls>
              </.timer_banner>
            </div>

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
                class="mb-4 flex items-start gap-3 rounded-box border border-warning/40 bg-warning/10 p-3"
              >
                <.icon name="hero-scale" class="size-5 shrink-0 mt-0.5 text-warning" />
                <div class="min-w-0 flex-1">
                  <p class="text-sm font-semibold leading-tight">Time for a weight check</p>
                  <p class="text-xs opacity-70 mt-0.5 leading-snug">
                    {weight_reminder_detail(@weight_reminder)}
                  </p>
                  <.link
                    navigate={~p"/c/#{@current_child}/vitals"}
                    class="text-xs text-primary hover:underline mt-1 inline-flex items-center gap-0.5"
                  >
                    Log it in Vitals <.icon name="hero-arrow-right" class="size-3" />
                  </.link>
                </div>
                <button
                  id="weight-check-reminder-dismiss"
                  type="button"
                  phx-click="dismiss_notice"
                  phx-value-key="weight-check"
                  class="btn btn-ghost btn-xs btn-circle -mr-1 -mt-1 shrink-0"
                  aria-label="Dismiss weight check reminder"
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </div>
            </div>

            <%!-- At a glance --%>
            <section class="bg-base-200/40 rounded-box p-2 space-y-2">
              <div id="glance-cards" class={["grid gap-2", glance_cols(@current_child)]}>
                <div :if={Child.tracks?(@current_child, :feeding)} id="glance-feed">
                  <.since_card
                    icon="hero-beaker"
                    label="Feeding"
                    category="feed"
                    tone={feed_tone(@outlook)}
                    value={feed_value(@summary.last_feeding, @outlook)}
                    sub={feed_sub(@summary.last_feeding, @outlook, @unit_system)}
                    status={feed_status(@summary.last_feeding, @outlook)}
                    today={feed_today(@summary.today, @unit_system)}
                  />
                </div>
                <div :if={Child.tracks?(@current_child, :diaper)} id="glance-diaper">
                  <.since_card
                    emoji={last_diaper_emoji(@summary.last_diaper)}
                    label="Diaper"
                    category="diaper"
                    tone={diaper_tone(@outlook)}
                    value={relative_time(time_of(@summary.last_diaper))}
                    sub={diaper_sub(@summary.last_diaper)}
                    status={diaper_status(@outlook)}
                    today={diaper_today(@summary.today)}
                  />
                </div>
                <div :if={Child.tracks?(@current_child, :sleep)} id="glance-sleep">
                  <.since_card
                    icon={sleep_icon(@summary)}
                    label={sleep_label(@summary)}
                    category="sleep"
                    tone={sleep_tone(@summary, @outlook)}
                    value={sleep_value(@summary, @outlook)}
                    sub={sleep_sub(@summary, @outlook, @current_child)}
                    status={sleep_status(@summary, @outlook)}
                    today={"#{format_duration(@summary.today.sleep_seconds)} slept today"}
                  />
                </div>
              </div>
            </section>

            <%!-- Log something --%>
            <div :if={@can_write} class="mt-6 rounded-box bg-base-200/40 p-3 space-y-3">
              <.button
                :if={Child.tracks?(@current_child, :sleep) and !sleeping?(@summary)}
                id="log-sleep"
                variant="primary"
                size="lg"
                phx-click="start_sleep"
                class="w-full text-base"
              >
                <.icon name="hero-moon" class="size-5" /> Start sleep
              </.button>

              <.button
                :if={Child.tracks?(@current_child, :feeding)}
                id="log-bottle"
                type="button"
                variant="info"
                size="lg"
                phx-click="open_sheet"
                phx-value-kind="bottle"
                class="w-full text-base"
              >
                <.icon name="hero-beaker" class="size-5" /> Log a bottle
              </.button>

              <div :if={Child.tracks?(@current_child, :diaper)} id="log-diaper">
                <div class="text-xs font-medium opacity-70 mb-1.5">Diaper</div>
                <div class="grid grid-cols-3 gap-2">
                  <.action_btn
                    :for={{emoji, value, label} <- diaper_choices()}
                    kind={"diaper_#{value}"}
                    label={label}
                    emoji={emoji}
                    color_class={diaper_color_class(value)}
                  />
                </div>
              </div>

              <.button
                type="button"
                variant="ghost"
                size="sm"
                phx-click="open_sheet"
                phx-value-kind="earlier"
                class="w-full"
              >
                <.icon name="hero-clock" class="size-4" /> Log from earlier
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
            class="mt-6 flex items-start gap-3 rounded-box border border-base-300 bg-base-200 p-3 text-sm"
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
            <button
              type="button"
              class="btn btn-ghost btn-xs btn-circle -mr-1 -mt-1"
              aria-label="Dismiss"
              data-push-prompt-action="dismiss"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
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
            <p :if={@entries_empty?} class="opacity-60 text-sm py-6 text-center">
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
      />

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

  ## Small render components ---------------------------------------------

  attr :kind, :string, required: true
  attr :label, :string, required: true
  attr :emoji, :string, required: true
  attr :color_class, :string, required: true

  defp action_btn(assigns) do
    ~H"""
    <.button
      type="button"
      phx-click="quick"
      phx-value-kind={@kind}
      class={["h-auto py-3 flex-col gap-1", @color_class]}
    >
      <span class="text-3xl leading-none" aria-hidden="true">{@emoji}</span>
      <span class="text-xs font-semibold">{@label}</span>
    </.button>
    """
  end

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

  defp sheet(assigns) do
    assigns = assign(assigns, :unit, Units.unit_label(:volume, assigns.unit_system))

    ~H"""
    <div
      id="quick-sheet"
      class="fixed inset-0 z-50 flex items-end sm:items-center justify-center"
      phx-window-keydown="close_sheet"
      phx-key="escape"
      phx-hook="ModalBack"
      data-close-event="close_sheet"
    >
      <div class="absolute inset-0 bg-black/60" phx-click="close_sheet"></div>
      <div class="relative w-full sm:max-w-md bg-base-100 border-t border-base-300 sm:border sm:rounded-box rounded-t-2xl p-5 pb-[calc(env(safe-area-inset-bottom)+1.25rem)] max-h-[90dvh] overflow-y-auto">
        <%= case @kind do %>
          <% :earlier -> %>
            <h3 class="font-semibold text-lg mb-1">Log from earlier</h3>
            <p class="text-sm opacity-60 mb-4">What do you want to add?</p>
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
              <.button type="button" variant="ghost" class="w-full" phx-click="close_sheet">
                Cancel
              </.button>
            </div>
          <% :bottle -> %>
            <h3 class="font-semibold text-lg mb-3">Log a bottle</h3>
            <.form
              for={@form}
              id="bottle-form"
              phx-change="sheet_change"
              phx-submit="save_sheet"
              class="space-y-4"
            >
              <div>
                <div class="flex items-center justify-center gap-4">
                  <.button
                    type="button"
                    variant="outline"
                    size="sm"
                    class="btn-circle"
                    phx-click="bump_amount"
                    phx-value-by={-fine_step(@unit_system)}
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
                      value={@form.params["amount"]}
                      class="text-3xl font-bold text-center tabular-nums w-20 bg-transparent focus:outline-none [appearance:textfield] [&::-webkit-outer-spin-button]:appearance-none [&::-webkit-inner-spin-button]:appearance-none"
                    />
                    <span class="text-base font-normal opacity-60">{@unit}</span>
                  </div>

                  <.button
                    type="button"
                    variant="outline"
                    size="sm"
                    class="btn-circle"
                    phx-click="bump_amount"
                    phx-value-by={fine_step(@unit_system)}
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
                    phx-click="bump_amount"
                    phx-value-by={step}
                  >
                    +{step}
                  </.button>
                  <.button
                    type="button"
                    variant="ghost"
                    size="sm"
                    id="bottle-reset"
                    phx-click="reset_amount"
                  >
                    Reset
                  </.button>
                </div>
              </div>

              <select name="entry[bottle_contents]" class="select select-bordered w-full">
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
                value={@form.params["note"]}
                placeholder="Note (optional)"
                class="input input-bordered w-full"
              />

              <.photo_field upload={@photo_upload} />

              <.sheet_buttons save="Save" uploading?={photo_uploading?(@photo_upload)} />
            </.form>
          <% :sleep_stop -> %>
            <h3 class="font-semibold text-lg mb-3">How did they sleep?</h3>
            <.form
              for={@form}
              id="sleep-form"
              phx-change="sheet_change"
              phx-submit="save_sleep"
              class="space-y-4"
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
            >
              <.time_field form={@form} field={:started_at} label="Fell asleep" />
              <.time_field form={@form} field={:ended_at} label="Woke up" />
              <.note_field form={@form} />
              <.photo_field upload={@photo_upload} />
              <.sheet_buttons save="Add sleep" uploading?={photo_uploading?(@photo_upload)} />
            </.form>
          <% :diaper_past -> %>
            <h3 class="font-semibold text-lg mb-3">Add a diaper from earlier</h3>
            <.form
              for={@form}
              id="diaper-form"
              phx-change="sheet_change"
              phx-submit="save_diaper"
              class="space-y-4"
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
          size="xs"
          phx-click="set_note"
          phx-value-text={n}
        >
          {n}
        </.button>
      </div>
      <.input
        field={@form[:note]}
        type="text"
        label="Note"
        placeholder="Anything to remember? (optional)"
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
          size="xs"
          phx-click="nudge_time"
          phx-value-field={@field}
          phx-value-by={mins}
        >
          {label}
        </.button>
      </div>
      <.input field={@form[@field]} type="datetime-local" label={@label} />
    </div>
    """
  end

  attr :save, :string, required: true
  attr :uploading?, :boolean, default: false

  defp sheet_buttons(assigns) do
    ~H"""
    <div class="flex gap-2 pt-1">
      <.save_button label={@save} uploading?={@uploading?} class="flex-1" />
      <.button type="button" variant="ghost" phx-click="close_sheet">Cancel</.button>
    </div>
    """
  end

  ## Presentation helpers ----------------------------------------------

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

  # Feed card. The primary `value` is plain time since the last feed — the
  # single most-checked fact — in the card's biggest text; the next-feed
  # estimate demotes to the neutral `sub` line. The tone-coloured `status`
  # only appears when something needs attention (a cluster in progress, or a
  # feed running later than the baby's own rhythm) — the sub line alone
  # doesn't carry enough weight to flag that on its own. The estimate comes
  # from their pattern, not a schedule, so the copy says "usual", never
  # "overdue" or "missed".
  @late_seconds -30 * 60

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

  defp diaper_sub(nil), do: "none yet"
  defp diaper_sub(%Entry{data: %{"kind" => k}}), do: String.capitalize(k)
  defp diaper_sub(_), do: nil

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
  defp sleeping?(%{running: running}), do: Enum.any?(running, &(&1.type == :sleep))

  defp running_sleep_entry(%{running: running}), do: Enum.find(running, &(&1.type == :sleep))

  defp woke_at(%{last_sleep: %Entry{ended_at: %DateTime{} = at}}), do: at
  defp woke_at(%{last_sleep: %Entry{started_at: at}}), do: at
  defp woke_at(_), do: nil

  defp sleep_icon(summary), do: if(sleeping?(summary), do: "hero-moon", else: "hero-sun")

  defp sleep_label(summary) do
    cond do
      sleeping?(summary) -> "Asleep"
      woke_at(summary) -> "Awake"
      true -> "Sleep"
    end
  end

  defp sleep_value(summary, outlook) do
    cond do
      e = running_sleep_entry(summary) ->
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
      e = running_sleep_entry(summary) ->
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

  # One glance card per tracked type, sharing the row evenly.
  defp glance_cols(child) do
    case length(child.tracked_types) do
      1 -> "grid-cols-1"
      2 -> "grid-cols-2"
      _ -> "grid-cols-3"
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
