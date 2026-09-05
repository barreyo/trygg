defmodule Trygg.Storage.S3 do
  @moduledoc """
  S3-compatible `Trygg.Storage` backed by Tigris (`fly.storage.tigris.dev`).

  Requests are plain HTTP against the bucket endpoint, signed with AWS
  Signature V4 by `Req`'s `:aws_sigv4` step. Configuration comes from
  `config :trygg, Trygg.Storage, …` (set from env vars in
  `config/runtime.exs`):

      adapter:           Trygg.Storage.S3
      bucket:            "trygg-uploads"
      endpoint_url:      "https://fly.storage.tigris.dev"
      region:            "auto"
      access_key_id:     …
      secret_access_key: …
  """

  @behaviour Trygg.Storage

  @impl true
  def put(key, body, content_type) do
    [method: :put, url: object_url(key), body: body, headers: [{"content-type", content_type}]]
    |> request()
    |> case do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get(key) do
    [method: :get, url: object_url(key)]
    |> request()
    |> case do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    [method: :delete, url: object_url(key)]
    |> request()
    |> case do
      {:ok, %{status: status}} when status in 200..299 or status == 404 -> :ok
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(opts) do
    config = config()

    [
      decode_body: false,
      retry: :transient,
      aws_sigv4: [
        service: "s3",
        region: config[:region] || "auto",
        access_key_id: config[:access_key_id],
        secret_access_key: config[:secret_access_key]
      ]
    ]
    |> Keyword.merge(opts)
    |> Req.request()
  end

  defp object_url(key) do
    config = config()

    endpoint =
      String.trim_trailing(config[:endpoint_url] || "https://fly.storage.tigris.dev", "/")

    encoded =
      key
      |> String.split("/")
      |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)

    "#{endpoint}/#{config[:bucket]}/#{encoded}"
  end

  defp config, do: Application.get_env(:trygg, Trygg.Storage, [])
end
