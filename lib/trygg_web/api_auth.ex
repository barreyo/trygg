defmodule TryggWeb.ApiAuth do
  @moduledoc """
  Authenticates REST API requests from an `Authorization: Bearer <token>`
  header (see `Trygg.ApiTokens`) and assigns the resulting `:current_scope`.

  The scope acts as the token's issuer, confined to the token's family and role.
  Anything else — no header, another scheme, an unknown, expired or orphaned
  token — gets the same `401`, so a caller learns nothing about which it was.
  """
  import Plug.Conn

  alias Trygg.ApiTokens

  def init(opts), do: opts

  def call(conn, _opts) do
    with [header] <- get_req_header(conn, "authorization"),
         [scheme, secret] <- String.split(header, " ", parts: 2),
         "bearer" <- String.downcase(scheme),
         {:ok, scope} <- ApiTokens.authenticate(String.trim(secret)) do
      assign(conn, :current_scope, scope)
    else
      _ -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", ~s(Bearer realm="trygg"))
    |> put_resp_content_type("application/json")
    |> send_resp(401, Phoenix.json_library().encode!(%{errors: %{detail: "Unauthorized"}}))
    |> halt()
  end
end
