defmodule TryggWeb.PhotoController do
  @moduledoc """
  `GET /c/:id/log/:entry_id/photo` — streams the photo attached to a log entry.

  Sits in the authenticated browser scope, so `current_scope` is on the conn.
  `Log.get_entry!/2` is membership-scoped: it raises (403 / 404) for anyone who
  isn't at least a viewer of the entry's child, so photos are exactly as
  private as the rest of the log.
  """
  use TryggWeb, :controller

  alias Trygg.Log

  def show(conn, %{"id" => child_id, "entry_id" => entry_id}) do
    entry = Log.get_entry!(conn.assigns.current_scope, entry_id)

    with true <- to_string(entry.child_id) == child_id,
         {:ok, body, content_type} <- Log.fetch_photo(entry) do
      conn
      |> put_resp_content_type(content_type, nil)
      |> put_resp_header("cache-control", "private, max-age=86400")
      |> send_resp(200, body)
    else
      _ -> send_resp(conn, 404, "")
    end
  end
end
