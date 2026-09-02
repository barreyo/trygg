defmodule TryggWeb.PreferencesLive do
  use TryggWeb, :live_view

  alias Trygg.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} title="Preferences" back={~p"/"}>
      <.header>
        Measurement units
        <:subtitle>Applies only to what you see. Amounts are stored the same for everyone.</:subtitle>
      </.header>

      <.form for={@form} id="preferences-form" phx-change="save" class="mt-4 space-y-3">
        <label class={unit_class(@form[:unit_system].value, :metric)}>
          <input
            type="radio"
            name="user[unit_system]"
            value="metric"
            class="radio radio-primary"
            checked={to_string(@form[:unit_system].value) == "metric"}
          />
          <span class="flex-1">
            <span class="font-medium block">Metric</span>
            <span class="text-sm opacity-70">millilitres, grams, centimetres</span>
          </span>
        </label>

        <label class={unit_class(@form[:unit_system].value, :imperial)}>
          <input
            type="radio"
            name="user[unit_system]"
            value="imperial"
            class="radio radio-primary"
            checked={to_string(@form[:unit_system].value) == "imperial"}
          />
          <span class="flex-1">
            <span class="font-medium block">Imperial</span>
            <span class="text-sm opacity-70">ounces, pounds, inches</span>
          </span>
        </label>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    {:ok, assign(socket, :form, to_form(Accounts.change_user_settings(user)))}
  end

  @impl true
  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.update_user_settings(socket.assigns.current_scope.user, params) do
      {:ok, user} ->
        socket =
          socket
          |> assign(:current_scope, %{socket.assigns.current_scope | user: user})
          |> assign(:form, to_form(Accounts.change_user_settings(user)))
          |> put_flash(:info, "Saved.")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp unit_class(current, value) do
    [
      "flex items-center gap-3 rounded-box border p-4 cursor-pointer",
      if(to_string(current) == to_string(value),
        do: "border-primary bg-primary/10",
        else: "border-base-300 bg-base-200"
      )
    ]
  end
end
