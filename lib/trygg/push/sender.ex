defmodule Trygg.Push.Sender do
  @moduledoc """
  The one impure step of sending a Web Push message: encrypt the payload for a
  subscription and POST it to the push service.

  Wrapped in a behaviour so tests can record calls instead of hitting the
  network. The implementation is chosen from
  `config :trygg, Trygg.Push, sender: ...` (defaults to
  `Trygg.Push.Sender.WebPush`; `:test` uses `Trygg.Push.Sender.Test`).
  """

  @typedoc """
  A subscription in the browser's `toJSON()` shape, with string keys:

      %{"endpoint" => "...", "keys" => %{"p256dh" => "...", "auth" => "..."}}
  """
  @type subscription :: %{required(String.t()) => term()}

  @type result :: {:ok, term()} | {:error, :expired} | {:error, term()}

  @doc "Delivers `message` (an already-encoded JSON string) to `subscription`."
  @callback deliver(subscription(), message :: String.t()) :: result()

  @doc "The configured sender implementation."
  @spec impl() :: module()
  def impl do
    Application.get_env(:trygg, Trygg.Push, [])
    |> Keyword.get(:sender, Trygg.Push.Sender.WebPush)
  end
end
