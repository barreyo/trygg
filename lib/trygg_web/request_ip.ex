defmodule TryggWeb.RequestIp do
  @moduledoc """
  Client IP for LiveView, preferring Fly's `fly-client-ip` over
  `x-forwarded-for` and falling back to the peer address.

  `connect_info` is only present during `mount/3`. Call this from mount and
  keep the result in socket assigns. On the static HTTP render Phoenix stores
  the `Plug.Conn`; after the socket connects it is a map of `:x_headers` /
  `:peer_data`.
  """

  @doc "Best-effort client IP string from a LiveView socket during mount."
  def from_socket(socket) do
    case socket.private[:connect_info] do
      %Plug.Conn{} = conn -> from_conn(conn)
      info when is_map(info) -> from_info(info)
      _ -> "unknown"
    end
  end

  defp from_conn(conn) do
    from_headers(conn.req_headers) || from_peer(%{address: conn.remote_ip}) || "unknown"
  end

  defp from_info(info) do
    headers = Map.get(info, :x_headers) || []
    peer = Map.get(info, :peer_data)
    from_headers(headers) || from_peer(peer) || "unknown"
  end

  defp from_headers(headers) do
    cond do
      value = header(headers, "fly-client-ip") -> value
      value = header(headers, "x-forwarded-for") -> first_forwarded(value)
      true -> nil
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) and is_binary(value) and value != "" ->
        if String.downcase(key) == name, do: value

      _ ->
        nil
    end)
  end

  defp first_forwarded(value) do
    value
    |> String.split(",", parts: 2)
    |> hd()
    |> String.trim()
  end

  defp from_peer(%{address: address}) when not is_nil(address) do
    address |> :inet.ntoa() |> to_string()
  end

  defp from_peer(_), do: nil
end
