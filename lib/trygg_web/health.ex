defmodule TryggWeb.Health do
  @moduledoc """
  Liveness/readiness probe used by Fly HTTP checks.

  Mounted as the first user plug in the endpoint so it never touches the
  session, CSRF, or LiveView. Database connectivity is part of readiness:
  a failing `SELECT 1` returns 503 so Fly stops sending traffic.
  """
  @behaviour Plug

  import Plug.Conn

  @path "/health"

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: @path} = conn, _opts) do
    {status, body} =
      case Ecto.Adapters.SQL.query(Trygg.Repo, "SELECT 1", []) do
        {:ok, _} -> {200, "ok"}
        {:error, _} -> {503, "unhealthy"}
      end

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
    |> halt()
  end

  def call(conn, _opts), do: conn

  @doc """
  Skip `Plug.SSL` redirects for Fly machine health checks.

  Plug 1.20 passes the whole connection to `exclude: [conn: {mod, fun, args}]`.
  """
  def ssl_excluded?(%Plug.Conn{host: host}), do: ssl_excluded_host?(host)

  @doc """
  Hosts that must skip `Plug.SSL` redirects.

  Fly's machine HTTP checks hit the VM by IP (no `X-Forwarded-Proto`), so
  any literal IP address is treated as an internal probe, along with loopback.
  """
  def ssl_excluded_host?(host) when host in ["localhost", "127.0.0.1", "::1"], do: true

  def ssl_excluded_host?(host) when is_binary(host) do
    case host |> strip_host_port() |> String.to_charlist() |> :inet.parse_address() do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  # `[fdaa::1]:8080` (IPv6 with port) or `127.0.0.1:8080`.
  defp strip_host_port("[" <> rest), do: rest |> String.split("]", parts: 2) |> hd()

  defp strip_host_port(host) do
    case String.split(host, ":", parts: 2) do
      [name, port] ->
        if port =~ ~r/^\d+$/, do: name, else: host

      [name] ->
        name
    end
  end
end
