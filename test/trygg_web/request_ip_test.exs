defmodule TryggWeb.RequestIpTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias TryggWeb.RequestIp

  test "reads fly-client-ip from a Plug.Conn during the static render" do
    conn = %Plug.Conn{
      req_headers: [{"fly-client-ip", "203.0.113.9"}, {"x-forwarded-for", "10.0.0.1"}],
      remote_ip: {127, 0, 0, 1}
    }

    assert RequestIp.from_socket(socket_with(conn)) == "203.0.113.9"
  end

  test "falls back to x-forwarded-for then peer address" do
    conn = %Plug.Conn{
      req_headers: [{"x-forwarded-for", "198.51.100.4, 10.0.0.1"}],
      remote_ip: {127, 0, 0, 1}
    }

    assert RequestIp.from_socket(socket_with(conn)) == "198.51.100.4"

    conn = %Plug.Conn{req_headers: [], remote_ip: {127, 0, 0, 1}}
    assert RequestIp.from_socket(socket_with(conn)) == "127.0.0.1"
  end

  test "reads connect_info map after the socket connects" do
    info = %{
      x_headers: [{"fly-client-ip", "192.0.2.10"}],
      peer_data: %{address: {10, 0, 0, 2}}
    }

    assert RequestIp.from_socket(socket_with(info)) == "192.0.2.10"
  end

  test "returns unknown when connect_info is missing" do
    assert RequestIp.from_socket(%Socket{private: %{}}) == "unknown"
  end

  defp socket_with(connect_info) do
    %Socket{private: %{connect_info: connect_info}}
  end
end
