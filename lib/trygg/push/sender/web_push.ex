defmodule Trygg.Push.Sender.WebPush do
  @moduledoc """
  Real `Trygg.Push.Sender`: hands off to `web_push_elixir`, which does the
  RFC 8291 payload encryption, signs the VAPID JWT, and POSTs via `Req`.

  VAPID keys come from `config :web_push_elixir` (set from env in
  `config/runtime.exs`).
  """
  @behaviour Trygg.Push.Sender

  @impl true
  def deliver(subscription, message) do
    subscription
    |> Jason.encode!()
    |> WebPushElixir.send_notification(message)
    |> normalize()
  end

  # Collapse the library's shapes into the behaviour's contract. A 404/410
  # means the browser dropped the subscription — the caller prunes it.
  defp normalize({:ok, _} = ok), do: ok
  defp normalize({:error, :expired}), do: {:error, :expired}
  defp normalize({:error, {:http_error, 404, _}}), do: {:error, :expired}
  defp normalize({:error, {:http_error, 410, _}}), do: {:error, :expired}
  defp normalize({:error, reason}), do: {:error, reason}
end
