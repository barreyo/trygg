defmodule TryggWeb.HealthTest do
  use TryggWeb.ConnCase, async: true

  test "GET /health is ok when the database is up", %{conn: conn} do
    conn = get(conn, "/health")

    assert conn.status == 200
    assert conn.resp_body == "ok"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "ssl_excluded_host?/1 treats loopback and IP probes as internal" do
    assert TryggWeb.Health.ssl_excluded_host?("localhost")
    assert TryggWeb.Health.ssl_excluded_host?("127.0.0.1")
    assert TryggWeb.Health.ssl_excluded_host?("::1")
    assert TryggWeb.Health.ssl_excluded_host?("fdaa:1:2:3::4")
    assert TryggWeb.Health.ssl_excluded_host?("172.19.0.5")
    assert TryggWeb.Health.ssl_excluded_host?("[fdaa:1:2:3::4]:8080")
    assert TryggWeb.Health.ssl_excluded_host?("127.0.0.1:8080")
    refute TryggWeb.Health.ssl_excluded_host?("track.backmanwong.family")
    refute TryggWeb.Health.ssl_excluded_host?("track.backmanwong.family:443")
  end

  test "ssl_excluded?/1 uses the connection host" do
    assert TryggWeb.Health.ssl_excluded?(%{build_conn() | host: "172.19.0.5"})
    refute TryggWeb.Health.ssl_excluded?(%{build_conn() | host: "track.backmanwong.family"})
  end
end
