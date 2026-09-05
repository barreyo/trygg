defmodule Trygg.Storage do
  @moduledoc """
  Blob storage for user-uploaded content (currently log-entry photos).

  Dispatches to a configured adapter:

    * `Trygg.Storage.Local` — writes to a directory on disk. The default on
      dev and test; nothing external to run.
    * `Trygg.Storage.S3` — an S3-compatible bucket (Tigris on Fly). Wired up
      in `config/runtime.exs` when the bucket env vars are present.

  Keys are opaque forward-slash-separated paths, e.g.
  `"children/42/log/1f9c….jpg"`. Nothing else in the app should assume where
  the bytes actually live.
  """

  @type key :: String.t()
  @type content_type :: String.t()

  @callback put(key, binary, content_type) :: :ok | {:error, term}
  @callback get(key) :: {:ok, binary} | {:error, term}
  @callback delete(key) :: :ok | {:error, term}

  @doc "Stores `body` under `key`, overwriting any existing object."
  def put(key, body, content_type) when is_binary(key) and is_binary(body),
    do: adapter().put(key, body, content_type)

  @doc "Reads the bytes stored under `key`."
  def get(key) when is_binary(key), do: adapter().get(key)

  @doc "Removes `key`. Succeeds even if the object is already gone."
  def delete(key) when is_binary(key), do: adapter().delete(key)

  @doc "The adapter module in effect for this environment."
  def adapter do
    :trygg
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:adapter, Trygg.Storage.Local)
  end
end
