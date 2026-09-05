defmodule TryggWeb.ObanDashboardAuth do
  @moduledoc """
  Gate for the Oban Web dashboard (`/oban`).

  There is no admin account concept in the app, so access is controlled by a
  dedicated credential pair:

    * With `config :trygg, :oban_dashboard, user: ..., password: ...` set
      (from `OBAN_DASHBOARD_USER` / `OBAN_DASHBOARD_PASSWORD` in
      `config/runtime.exs`), the dashboard is behind HTTP Basic Auth.
    * Without it, in an environment where `:dev_routes` is enabled, the
      dashboard is open — same posture as `LiveDashboard` in development.
    * Otherwise the route 404s, so a production release without the secrets
      simply doesn't expose it.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    config = Application.get_env(:trygg, :oban_dashboard, [])
    user = config[:user]
    pass = config[:password]

    cond do
      is_binary(user) and is_binary(pass) and user != "" and pass != "" ->
        Plug.BasicAuth.basic_auth(conn, username: user, password: pass)

      Application.get_env(:trygg, :dev_routes, false) ->
        conn

      true ->
        conn |> send_resp(404, "Not found") |> halt()
    end
  end
end
