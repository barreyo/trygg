defmodule TryggWeb.Api.DeviceControllerTest do
  use TryggWeb.ConnCase, async: true

  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.{ApiTokens, Devices}

  setup %{conn: conn} do
    scope = user_scope_fixture()
    child = child_fixture(scope)
    conn = put_req_header(conn, "content-type", "application/json")
    %{conn: conn, scope: scope, child: child}
  end

  defp bearer(conn, scope, child, role) do
    {:ok, token} = ApiTokens.create_token(scope, child.family_id, %{name: "test", role: role})
    put_req_header(conn, "authorization", "Bearer " <> token.secret)
  end

  defp reading(conn, id, body),
    do: post(conn, ~p"/api/v1/devices/#{id}/readings", Jason.encode!(body))

  @sample %{temperature_c: 21.5, humidity_pct: 45.0, pressure_hpa: 1012.0, gas_ohms: 90_000}

  test "a new device registers itself on its first reading", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    conn = bearer(conn, scope, child, :caregiver)

    assert %{
             "data" => %{
               "hardware_id" => "AA:BB:CC:DD:EE:FF",
               "short_id" => short_id,
               "name" => nil,
               "latest" => latest
             }
           } =
             conn
             |> reading("AA:BB:CC:DD:EE:FF", Map.put(@sample, :model, "env_pro"))
             |> json_response(201)

    assert short_id in 10_000..99_999
    assert latest["temperature_c"] == 21.5

    assert [%{model: "env_pro", name: nil}] = Devices.list_devices(scope, child.family_id)
  end

  test "readings reach subscribers live", %{conn: conn, scope: scope, child: child} do
    Devices.subscribe(child.family_id)
    conn |> bearer(scope, child, :caregiver) |> reading("dev-1", @sample) |> json_response(201)
    assert_receive {:device_reading, %{hardware_id: "dev-1"}, %{humidity_pct: 45.0}}
  end

  test "GET /devices lists devices with their latest reading and the name", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    conn |> bearer(scope, child, :caregiver) |> reading("dev-1", @sample) |> json_response(201)
    [device] = Devices.list_devices(scope, child.family_id)
    {:ok, _} = Devices.name_device(scope, device, %{"name" => "Nursery"})

    assert %{"data" => [%{"name" => "Nursery", "latest" => %{"pressure_hpa" => 1012.0}}]} =
             conn
             |> bearer(scope, child, :viewer)
             |> get(~p"/api/v1/devices")
             |> json_response(200)
  end

  test "invalid readings are 422", %{conn: conn, scope: scope, child: child} do
    conn = bearer(conn, scope, child, :caregiver)
    assert %{"errors" => _} = conn |> reading("dev-1", %{humidity_pct: 150}) |> json_response(422)
    assert %{"errors" => _} = conn |> reading("dev-1", %{}) |> json_response(422)
  end

  test "a read-only token can't report; no token is 401", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    assert_error_sent 403, fn ->
      conn |> bearer(scope, child, :viewer) |> reading("dev-1", @sample)
    end

    assert conn |> reading("dev-1", @sample) |> response(401)
    assert conn |> get(~p"/api/v1/devices") |> response(401)
  end
end
