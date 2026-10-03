defmodule TryggWeb.Api.FirmwareController do
  @moduledoc """
  The M5Stack button updates itself from here: `GET /api/v1/firmware/button` says
  which build is current and `GET /api/v1/firmware/button/image` is the image.
  Any valid token will do; the firmware is no secret, but there's no reason to
  hand it to strangers either.
  """
  use TryggWeb, :controller

  alias Trygg.Firmware

  action_fallback TryggWeb.Api.FallbackController

  def show(conn, _params) do
    with {:ok, release} <- fetch_latest() do
      json(conn, Map.take(release, [:version, :size, :md5]))
    end
  end

  # `x-md5` is what the ESP32's HTTPUpdate checks the download against.
  def image(conn, _params) do
    with {:ok, release} <- fetch_latest() do
      conn
      |> put_resp_header("x-md5", release.md5)
      |> put_resp_content_type("application/octet-stream")
      |> send_file(200, release.path)
    end
  end

  defp fetch_latest do
    case Firmware.latest() do
      {:ok, release} -> {:ok, release}
      :error -> {:error, :not_found}
    end
  end
end
