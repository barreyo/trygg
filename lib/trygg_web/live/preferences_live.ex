defmodule TryggWeb.PreferencesLive do
  use TryggWeb, :live_view

  alias Trygg.Accounts
  alias Trygg.Push

  @reminder_options [
    {"", "Recommended schedule", "follows the CDC well-child visit spacing for their age"},
    {"7", "Every 7 days", nil},
    {"14", "Every 14 days", nil},
    {"30", "Every 30 days", nil},
    {"0", "Off", "no weight-check reminders"}
  ]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} title="Preferences" back={~p"/"}>
      <.header>
        Measurement units
        <:subtitle>Applies only to what you see. Amounts are stored the same for everyone.</:subtitle>
      </.header>

      <.form
        for={@form}
        id="preferences-form"
        phx-change="save"
        phx-hook="Theme"
        class="mt-4 space-y-3"
      >
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

        <div class="pt-6">
          <.header>
            Weight-check reminders
            <:subtitle>
              A nudge — on the home screen and by email — when a child's weight hasn't been
              logged in a while. This is your setting; it doesn't change it for other caregivers.
            </:subtitle>
          </.header>
        </div>

        <div id="reminder-options" class="space-y-3">
          <label
            :for={{value, title, hint} <- reminder_options()}
            class={option_class(reminder_value(@form[:weight_reminder_days].value), value)}
          >
            <input
              type="radio"
              name="user[weight_reminder_days]"
              value={value}
              class="radio radio-primary"
              checked={reminder_value(@form[:weight_reminder_days].value) == value}
            />
            <span class="flex-1">
              <span class="font-medium block">{title}</span>
              <span :if={hint} class="text-sm opacity-70">{hint}</span>
            </span>
          </label>
        </div>
      </.form>

      <div class="pt-6">
        <.header>
          Notifications
          <:subtitle>
            A gentle heads-up on this device — like a weight check coming due — even when Trygg isn't open.
          </:subtitle>
        </.header>
      </div>

      <div
        :if={@vapid_public_key}
        id="push-notifications"
        phx-hook="PushNotifications"
        phx-update="ignore"
        data-vapid-key={@vapid_public_key}
        class="mt-4 rounded-box border border-base-300 bg-base-200 p-4 space-y-3"
      >
        <p data-push-status class="text-sm opacity-80">Checking this device…</p>

        <.button
          type="button"
          data-push-action="enable"
          variant="primary"
          size="sm"
          hidden
        >
          Turn on notifications
        </.button>

        <.button
          type="button"
          data-push-action="disable"
          variant="outline"
          size="sm"
          hidden
        >
          Turn off on this device
        </.button>

        <p data-push-unsupported hidden class="text-sm opacity-80">
          This browser can't show notifications yet. On an iPhone or iPad, add Trygg to your Home Screen first, then come back here.
        </p>
      </div>

      <p :if={!@vapid_public_key} class="mt-4 text-sm opacity-70">
        Notifications aren't set up on this server yet.
      </p>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(:form, to_form(Accounts.change_user_settings(user)))
     |> assign(:vapid_public_key, Push.vapid_public_key())}
  end

  @impl true
  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.update_user_settings(socket.assigns.current_scope.user, normalize(params)) do
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

  # A blank "Recommended schedule" radio submits "", which Ecto's cast would
  # treat as "no change"; make it an explicit clear instead.
  defp normalize(%{"weight_reminder_days" => ""} = params),
    do: %{params | "weight_reminder_days" => nil}

  defp normalize(params), do: params

  defp reminder_options, do: @reminder_options

  # Normalise the stored value (nil | integer) to the radio's string value.
  defp reminder_value(nil), do: ""
  defp reminder_value(n) when is_integer(n), do: to_string(n)
  defp reminder_value(s) when is_binary(s), do: s

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
