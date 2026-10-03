defmodule Trygg.Firmware do
  @moduledoc """
  The released firmware for the M5Stack button, served so the device can update
  itself over the air (`GET /api/v1/firmware/button`).

  A release is two files in `priv/firmware/` (or `:firmware_dir`): `button.bin`,
  the image PlatformIO built, and `button.json`, which says which build it is
  (`version`, a Unix timestamp the firmware compares with its own). `make
  fw-release` writes both; they ship with the app like any other `priv` file.
  """

  @device "button"

  @type release :: %{version: integer(), size: non_neg_integer(), md5: String.t(), path: Path.t()}

  @doc "The current release for the button, or `:error` when none has been published."
  @spec latest() :: {:ok, release()} | :error
  def latest do
    with {:ok, json} <- File.read(file("#{@device}.json")),
         {:ok, %{"version" => version, "md5" => md5}} when is_integer(version) <-
           Jason.decode(json),
         path = file("#{@device}.bin"),
         {:ok, %File.Stat{size: size, type: :regular}} <- File.stat(path) do
      {:ok, %{version: version, size: size, md5: md5, path: path}}
    else
      _ -> :error
    end
  end

  defp file(name), do: Path.join(dir(), name)

  defp dir do
    Application.get_env(:trygg, :firmware_dir) || Path.join(:code.priv_dir(:trygg), "firmware")
  end
end
