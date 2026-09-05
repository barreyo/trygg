defmodule TryggWeb.PushSubscriptionController do
  @moduledoc """
  Stores and removes the current user's Web Push subscriptions.

  A plain JSON controller rather than a LiveView event: the service-worker /
  `PushManager` dance in `assets/js/hooks/push_notifications.js` isn't bound to
  a live socket, and the browser can re-`POST` a refreshed subscription at any
  time. Same session auth as the LiveViews (`:require_authenticated_user`).
  """
  use TryggWeb, :controller

  alias Trygg.Push

  @doc """
  `POST /push/subscriptions` — body is the browser's
  `PushSubscription.toJSON()` (`endpoint` + `keys`). Idempotent per endpoint.
  """
  def create(conn, params) do
    user = conn.assigns.current_scope.user

    attrs =
      params
      |> Map.take(["endpoint", "keys"])
      |> Map.put("user_agent", user_agent(conn))

    case Push.subscribe(user, attrs) do
      {:ok, _subscription} ->
        send_resp(conn, :created, "")

      {:error, %Ecto.Changeset{}} ->
        send_resp(conn, :unprocessable_entity, "")
    end
  end

  @doc """
  `DELETE /push/subscriptions` — body `{"endpoint": "..."}`. Always 204, even
  if nothing matched (the client just wants the row gone).
  """
  def delete(conn, %{"endpoint" => endpoint}) when is_binary(endpoint) do
    Push.unsubscribe(endpoint)
    send_resp(conn, :no_content, "")
  end

  def delete(conn, _params), do: send_resp(conn, :bad_request, "")

  defp user_agent(conn) do
    conn
    |> get_req_header("user-agent")
    |> List.first()
    |> case do
      ua when is_binary(ua) -> String.slice(ua, 0, 512)
      _ -> nil
    end
  end
end
