defmodule TryggWeb.ChildLive.Index do
  use TryggWeb, :live_view

  alias Trygg.Families
  alias Trygg.Families.Child

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} title="Children">
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

      <ul class="space-y-3">
        <li :for={child <- @children}>
          <.link
            navigate={~p"/c/#{child}"}
            class="flex items-center gap-3 rounded-box border border-base-300 bg-base-200 p-4 hover:bg-base-300 hover:border-base-content/20 transition-colors"
          >
            <div class="size-11 rounded-full bg-primary/15 text-primary grid place-items-center font-semibold">
              {String.first(child.name)}
            </div>
            <div class="flex-1 min-w-0">
              <div class="font-semibold truncate">{child.name}</div>
              <div class="text-sm opacity-60">{age_line(child)}</div>
            </div>
            <span class="badge badge-ghost badge-sm">{child.role}</span>
            <.icon name="hero-chevron-right" class="size-5 opacity-40" />
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
      title={if @live_action == :new, do: "Add child", else: "Edit child"}
      back={~p"/children"}
    >
      <.form
        for={@form}
        id="child-form"
        phx-change="validate"
        phx-submit="save"
        class="space-y-4 mt-2"
      >
        <.input field={@form[:name]} label="Name" required autocomplete="off" />
        <.input field={@form[:birth_date]} type="date" label="Birth date" />
        <.input field={@form[:birth_time]} type="time" label="Birth time (optional)" />
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
          <.button variant="primary" phx-disable-with="Saving…" class="flex-1">Save</.button>
          <.button variant="ghost" navigate={~p"/children"}>Cancel</.button>
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
    |> assign(:form, to_form(Families.change_child(%Child{})))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    child = Families.get_child!(socket.assigns.current_scope, id)

    socket
    |> assign(:child, child)
    |> assign(:form, to_form(Families.change_child(child)))
  end

  @impl true
  def handle_event("validate", %{"child" => params}, socket) do
    changeset = Families.change_child(socket.assigns.child, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(changeset))}
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
    case Families.update_child(socket.assigns.current_scope, socket.assigns.child, params) do
      {:ok, child} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved.")
         |> push_navigate(to: ~p"/c/#{child}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp age_line(%Child{birth_date: nil}), do: "—"

  defp age_line(%Child{birth_date: date}) do
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
