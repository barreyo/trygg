defmodule TryggWeb.Api.FirmwareControllerTest do
  # Points the app at a temp firmware dir, which is global state.
  use TryggWeb.ConnCase, async: false

  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.ApiTokens

  @image "not really firmware"

  setup %{conn: conn, tmp_dir: dir} do
    previous = Application.get_env(:trygg, :firmware_dir)
    Application.put_env(:trygg, :firmware_dir, dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:trygg, :firmware_dir, previous),
        else: Application.delete_env(:trygg, :firmware_dir)
    end)

    scope = user_scope_fixture()
    child = child_fixture(scope)
    {:ok, token} = ApiTokens.create_token(scope, child.family_id, %{name: "t", role: :viewer})
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> token.secret), dir: dir}
  end

  defp publish(dir, manifest \\ %{version: 1_767_000_000, md5: "abc123"}) do
    File.write!(Path.join(dir, "button.bin"), @image)
    File.write!(Path.join(dir, "button.json"), Jason.encode!(manifest))
  end

  @moduletag :tmp_dir

  test "requires a token", %{dir: dir} do
    publish(dir)

    for path <- [~p"/api/v1/firmware/button", ~p"/api/v1/firmware/button/image"] do
      assert build_conn() |> get(path) |> json_response(401)
    end
  end

  test "describes the current release", %{conn: conn, dir: dir} do
    publish(dir)

    assert %{"version" => 1_767_000_000, "md5" => "abc123", "size" => size} =
             conn |> get(~p"/api/v1/firmware/button") |> json_response(200)

    assert size == byte_size(@image)
  end

  test "serves the image with its md5", %{conn: conn, dir: dir} do
    publish(dir)
    conn = get(conn, ~p"/api/v1/firmware/button/image")

    assert response(conn, 200) == @image
    assert ["abc123"] = get_resp_header(conn, "x-md5")
    assert ["application/octet-stream" <> _] = get_resp_header(conn, "content-type")
  end

  test "is a 404 until a release is published", %{conn: conn} do
    assert conn |> get(~p"/api/v1/firmware/button") |> json_response(404)
    assert conn |> get(~p"/api/v1/firmware/button/image") |> json_response(404)
  end

  test "a half-written release is a 404", %{conn: conn, dir: dir} do
    publish(dir, %{version: "soon"})
    assert conn |> get(~p"/api/v1/firmware/button") |> json_response(404)

    File.rm!(Path.join(dir, "button.bin"))
    publish(dir)
    File.rm!(Path.join(dir, "button.bin"))
    assert conn |> get(~p"/api/v1/firmware/button") |> json_response(404)
  end
end
