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
        <label class={option_class(@form[:unit_system].value, :metric)}>
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

        <label class={option_class(@form[:unit_system].value, :imperial)}>
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

        <div class="pt-6">
          <.header>
            Appearance
            <:subtitle>Choose a light or dark look, or follow your device.</:subtitle>
          </.header>
        </div>

        <label class={option_class(@form[:theme].value, :system)}>
          <input
            type="radio"
            name="user[theme]"
            value="system"
            class="radio radio-primary"
            checked={to_string(@form[:theme].value) == "system"}
          />
          <span class="flex-1">
            <span class="font-medium block">System</span>
            <span class="text-sm opacity-70">Match your device's light or dark setting</span>
          </span>
        </label>

        <label class={option_class(@form[:theme].value, :light)}>
          <input
            type="radio"
            name="user[theme]"
            value="light"
            class="radio radio-primary"
            checked={to_string(@form[:theme].value) == "light"}
          />
          <span class="flex-1">
            <span class="font-medium block">Light</span>
            <span class="text-sm opacity-70">Always use the light theme</span>
          </span>
        </label>

        <label class={option_class(@form[:theme].value, :dark)}>
          <input
            type="radio"
            name="user[theme]"
            value="dark"
            class="radio radio-primary"
            checked={to_string(@form[:theme].value) == "dark"}
          />
          <span class="flex-1">
            <span class="font-medium block">Dark</span>
            <span class="text-sm opacity-70">Always use the dark theme</span>
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
          |> push_event("set-theme", %{theme: to_string(user.theme)})

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp option_class(current, value) do
    [
      "flex items-center gap-3 rounded-box border p-4 cursor-pointer",
      if(to_string(current) == to_string(value),
        do: "border-primary bg-primary/10",
        else: "border-base-300 bg-base-200"
      )
    ]
  end
end
