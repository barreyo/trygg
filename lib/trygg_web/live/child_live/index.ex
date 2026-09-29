defmodule TryggWeb.ChildLive.Index do
  use TryggWeb, :live_view

  alias Trygg.Families
  alias Trygg.Families.Child

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} title="Children" back={~p"/"}>
      <:actions>
        <.button variant="primary" size="sm" navigate={~p"/children/new"}>
          <.icon name="hero-plus" class="size-4" /> Add
        </.button>
      </:actions>

      <div :if={@children == []} class="text-center py-16 opacity-70">
        <.icon name="hero-user-plus" class="size-10 mx-auto mb-3" />
        <p>No children yet.</p>
        <.button variant="primary" size="sm" navigate={~p"/children/new"} class="mt-4">
          Add your first
        </.button>
      </div>

      <ul id="children-list" class="space-y-3">
        <li
          :for={child <- @children}
          id={"child-#{child.id}"}
          class="flex items-stretch rounded-box border border-base-300 bg-base-200 overflow-hidden"
        >
          <.link
            navigate={~p"/c/#{child}"}
            class="flex-1 min-w-0 flex items-center gap-3 p-4 hover:bg-base-300 transition-colors"
          >
            <div class="size-11 rounded-full bg-primary/15 text-primary grid place-items-center font-semibold shrink-0">
              {String.first(child.name)}
            </div>
            <div class="flex-1 min-w-0">
              <div class="font-semibold truncate">{child.name}</div>
              <div class="text-sm opacity-60">{age_line(child)}</div>
            </div>
            <span class="badge badge-ghost badge-sm">{child.role}</span>
          </.link>
          <.link
            :if={child.role == :owner}
            id={"edit-child-#{child.id}"}
            navigate={~p"/children/#{child}/edit"}
            class="flex items-center px-4 border-l border-base-300 hover:bg-base-300 transition-colors"
            aria-label={"Edit #{child.name}"}
          >
            <.icon name="hero-pencil-square" class="size-5 opacity-60" />
          </.link>
        </li>
      </ul>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      title={if @live_action == :new, do: "Add child", else: "Edit #{@child.name}"}
      back={cancel_path(@live_action, @child)}
    >
      <.form
        for={@form}
        id="child-form"
        phx-change="validate"
        phx-submit="save"
        class="space-y-4 mt-2"
      >
        <.input field={@form[:name]} label="Name" required autocomplete="off" />

        <div :if={status_choice?(assigns)} class="join w-full">
          <button
            :for={{value, label} <- [{"born", "Already born"}, {"expecting", "Expecting"}]}
            type="button"
            phx-click="set_status"
            phx-value-status={value}
            aria-pressed={to_string(@status == String.to_existing_atom(value))}
            class={[
              "join-item btn flex-1",
              @status == String.to_existing_atom(value) && "btn-primary"
            ]}
          >
            {label}
          </button>
        </div>

        <%= if @status == :expecting do %>
          <.input
            field={@form[:expected_birth_date]}
            type="date"
            label="Due date"
            required
          />
          <p :if={not entering_demo?(assigns)} class="text-xs opacity-60 -mt-2">
            You can set everything up and start tracking now. It's all practice until {@form[:name].value ||
              "the baby"} arrives — then the practice log clears.
          </p>
          <p :if={entering_demo?(assigns)} class="text-xs text-warning -mt-2">
            Switching {@child.name} to practice mode clears their birth date. Anything
            logged so far becomes practice data and is removed when you next confirm the
            birth.
          </p>
        <% else %>
          <.input field={@form[:birth_date]} type="date" label="Birth date" />
          <.input field={@form[:birth_time]} type="time" label="Birth time (optional)" />
          <div class="grid grid-cols-[2fr_1fr] gap-2">
            <.input
              field={@form[:gestation_weeks]}
              type="select"
              label="Born at (optional)"
              prompt="Full term / not sure"
              options={Enum.map(Child.gestation_weeks(), &{"#{&1} weeks", &1})}
            />
            <.input
              field={@form[:gestation_extra_days]}
              type="select"
              label="+ days"
              options={Enum.map(0..6, &{"+#{&1}", &1})}
            />
          </div>
          <p id="gestation-help" class="text-xs opacity-60 -mt-2">{gestation_help(@child)}</p>
          <p
            :if={@live_action == :edit and Child.expecting?(@child)}
            class="text-xs text-warning -mt-2"
          >
            Saving with a birth date marks {@child.name} as born and clears the practice
            entries you've added.
          </p>
        <% end %>

        <.button
          :if={@live_action == :edit and Child.expecting?(@child) and @status == :expecting}
          type="button"
          variant="primary"
          size="sm"
          phx-click="set_status"
          phx-value-status="born"
          class="w-full"
        >
          🎉 {@child.name} has arrived
        </.button>

        <.input
          field={@form[:sex]}
          type="select"
          label="Sex"
          options={Enum.map(Child.sexes(), &{Phoenix.Naming.humanize(&1), &1})}
        />
        <.input
          field={@form[:timezone]}
          type="select"
          label="Time zone"
          options={timezone_options()}
        />
        <.input
          field={@form[:day_start]}
          type="time"
          label="Day starts"
        />
        <.input
          field={@form[:night_start]}
          type="time"
          label="Night starts"
        />

        <div class="flex gap-2 pt-2">
          <.button
            variant="primary"
            phx-disable-with="Saving…"
            class="flex-1"
            data-confirm={save_confirm(assigns)}
          >
            Save
          </.button>
          <.button variant="ghost" navigate={cancel_path(@live_action, @child)}>Cancel</.button>
        </div>

        <.button
          :if={@live_action == :edit and @child.role == :owner}
          type="button"
          variant="outline"
          size="sm"
          phx-click="delete"
          data-confirm={"Delete #{@child.name} and all their logs? This can't be undone."}
          class="btn-error w-full mt-6"
        >
          Delete child
        </.button>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Trygg.Accounts.subscribe_user(socket.assigns.current_scope.user.id)

    {:ok, assign(socket, :children, Families.list_children(socket.assigns.current_scope))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_info({:children_changed, _user_id}, socket) do
    {:noreply, assign(socket, :children, Families.list_children(socket.assigns.current_scope))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp apply_action(socket, :index, _params) do
    assign(socket, children: Families.list_children(socket.assigns.current_scope), child: nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:child, %Child{})
    |> assign(:status, :born)
    |> assign(:form, to_form(Families.change_child(%Child{})))
  end

  defp apply_action(socket, :edit, %{"id" => id} = params) do
    child = Families.get_child!(socket.assigns.current_scope, id)

    if child.role == :owner do
      # The "… has arrived" banner links here with ?arrived=1 to jump straight
      # to confirming the birth date.
      status =
        if Child.expecting?(child) and params["arrived"] != "1", do: :expecting, else: :born

      form = child |> Families.change_child(arrived_defaults(child, status)) |> to_form()

      socket
      |> assign(:child, child)
      |> assign(:status, status)
      |> assign(:form, form)
    else
      socket
      |> put_flash(:error, "Only #{child.name}'s owners can edit their details.")
      |> push_navigate(to: ~p"/c/#{child}")
    end
  end

  # When an expecting child is being marked born, pre-fill the birth date with
  # their local today so the caregiver usually just taps Save.
  defp arrived_defaults(child, :born) do
    if Child.expecting?(child),
      do: %{"birth_date" => Date.to_iso8601(Child.local_today(child))},
      else: %{}
  end

  defp arrived_defaults(_child, _status), do: %{}

  # Where Back / Cancel lead: a new child hasn't got a page yet, an existing one does.
  defp cancel_path(:edit, %Child{id: id} = child) when not is_nil(id), do: ~p"/c/#{child}"
  defp cancel_path(_action, _child), do: ~p"/children"

  @impl true
  def handle_event("validate", %{"child" => params}, socket) do
    changeset = Families.change_child(socket.assigns.child, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("set_status", %{"status" => status}, socket) do
    status = String.to_existing_atom(status)

    params =
      Map.merge(current_form_params(socket), arrived_defaults(socket.assigns.child, status))

    {:noreply,
     socket
     |> assign(:status, status)
     |> assign(:form, to_form(Families.change_child(socket.assigns.child, params)))}
  end

  def handle_event("save", %{"child" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  def handle_event("delete", _params, socket) do
    {:ok, _} = Families.delete_child(socket.assigns.current_scope, socket.assigns.child)

    {:noreply,
     socket
     |> put_flash(:info, "Child deleted.")
     |> push_navigate(to: ~p"/children")}
  end

  defp save(socket, :new, params) do
    case Families.create_child(socket.assigns.current_scope, params) do
      {:ok, child} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{child.name} added.")
         |> push_navigate(to: ~p"/c/#{child}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp save(socket, :edit, params) do
    was_expecting? = Child.expecting?(socket.assigns.child)

    case Families.update_child(socket.assigns.current_scope, socket.assigns.child, params) do
      {:ok, child} ->
        message =
          cond do
            was_expecting? and not Child.expecting?(child) ->
              "#{child.name} is here! 🎉 Welcome to the world."

            not was_expecting? and Child.expecting?(child) ->
              "#{child.name} is back in practice mode."

            true ->
              "Saved."
          end

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> push_navigate(to: ~p"/c/#{child}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp current_form_params(socket) do
    case socket.assigns.form do
      %{params: params} when is_map(params) -> params
      _ -> %{}
    end
  end

  # The "Already born / Expecting" segmented control shows on the new-child form
  # and on every edit form, so an owner can move a child into or out of practice
  # mode from the child's settings.
  defp status_choice?(%{live_action: action}) when action in [:new, :edit], do: true
  defp status_choice?(_assigns), do: false

  # True while editing a currently-born child with the toggle flipped to
  # "Expecting" — i.e. about to drop them back into practice mode.
  defp entering_demo?(%{live_action: :edit, status: :expecting, child: %Child{id: id} = child})
       when not is_nil(id),
       do: not Child.expecting?(child)

  defp entering_demo?(_assigns), do: false

  defp save_confirm(%{live_action: :edit, status: :born, child: child}) do
    if Child.expecting?(child),
      do: "Mark #{child.name} as born? This clears every practice entry you've added.",
      else: false
  end

  defp save_confirm(assigns) do
    if entering_demo?(assigns),
      do:
        "Switch #{assigns.child.name} to practice mode? Their birth date is cleared and " <>
          "everything logged so far becomes practice data — it's removed when you next " <>
          "confirm the birth.",
      else: false
  end

  defp gestation_help(%Child{} = child) do
    if Child.expecting?(child) do
      "Leave blank to work it out from the due date, " <>
        Calendar.strftime(child.expected_birth_date, "%b %-d") <> "."
    else
      "For babies born before 39 weeks, growth, sleep and feeding guides use corrected age until age 2."
    end
  end

  defp age_line(%Child{} = child) do
    cond do
      Child.expecting?(child) -> Child.due_label(child)
      is_nil(child.birth_date) -> "—"
      true -> born_age_line(child.birth_date)
    end
  end

  defp born_age_line(date) do
    days = Date.diff(Date.utc_today(), date)

    cond do
      days < 0 -> "not born yet"
      days == 0 -> "born today"
      days < 14 -> "#{days} days old"
      days < 60 -> "#{div(days, 7)} weeks old"
      days < 730 -> "#{div(days, 30)} months old"
      true -> "#{div(days, 365)} years old"
    end
  end

  # A short, friendly menu; the stored value is a real IANA zone so DST is
  # handled automatically. Add more as people need them.
  @timezone_choices [
    {"Pacific — Los Angeles / San Francisco", "America/Los_Angeles"},
    {"Mountain — Denver", "America/Denver"},
    {"Mountain (no DST) — Phoenix", "America/Phoenix"},
    {"Central — Chicago", "America/Chicago"},
    {"Eastern — New York", "America/New_York"},
    {"Alaska — Anchorage", "America/Anchorage"},
    {"Hawaii — Honolulu", "Pacific/Honolulu"},
    {"UK — London", "Europe/London"},
    {"Central Europe — Paris / Berlin", "Europe/Paris"},
    {"India — Kolkata", "Asia/Kolkata"},
    {"Japan — Tokyo", "Asia/Tokyo"},
    {"Australia Eastern — Sydney", "Australia/Sydney"},
    {"UTC", "Etc/UTC"}
  ]

  defp timezone_options, do: @timezone_choices
end
