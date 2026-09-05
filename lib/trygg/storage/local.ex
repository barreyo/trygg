defmodule Trygg.Storage.Local do
  @moduledoc """
  Filesystem-backed `Trygg.Storage`. Objects are plain files under a base
  directory (`config :trygg, Trygg.Storage, base_dir: …`, defaulting to
  `priv/uploads`). Used on dev and test; production uses `Trygg.Storage.S3`.
  """

  @behaviour Trygg.Storage

  @impl true
  def put(key, body, _content_type) do
    path = path(key)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, body)
    end
  end

  @impl true
  def get(key) do
    case File.read(path(key)) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    case File.rm(path(key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def base_dir do
    :trygg
    |> Application.get_env(Trygg.Storage, [])
    |> Keyword.get(:base_dir)
    |> case do
      nil -> Path.join(:code.priv_dir(:trygg), "uploads")
      dir -> dir
    end
  end

  # Resolve a key to an absolute path, dropping any "", "." or ".." segments so
  # a crafted key can't escape the base directory.
  defp path(key) do
    safe =
      key
      |> Path.split()
      |> Enum.reject(&(&1 in ["", ".", ".."]))
      |> Path.join()

    Path.join(base_dir(), safe)
  end
end
