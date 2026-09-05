defmodule Trygg.Push do
  @moduledoc """
  Web Push subscriptions and delivery for the installed PWA.

  A subscription is created by the browser after the user grants notification
  permission (see `assets/js/hooks/push_notifications.js`) and POSTed to
  `TryggWeb.PushSubscriptionController`. Delivery encrypts a JSON payload per
  subscription and POSTs it to the push service via `Trygg.Push.Sender`;
  subscriptions the service reports as gone (404/410) are pruned.

  Push is a best-effort companion to email, never a replacement — every
  function degrades quietly when VAPID keys are unset or push is disabled
  (`config :trygg, Trygg.Push, enabled: false`), mirroring how the mailer
  degrades without its config.
  """
  import Ecto.Query, warn: false

  require Logger

  alias Trygg.Accounts.User
  alias Trygg.Push.DeliveryWorker
  alias Trygg.Push.Sender
  alias Trygg.Push.Subscription
  alias Trygg.Repo

  @doc """
  Whether push delivery should be attempted: not disabled in config, and a
  VAPID keypair is present.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    config_enabled?() and vapid_configured?()
  end

  defp config_enabled? do
    Application.get_env(:trygg, __MODULE__, []) |> Keyword.get(:enabled, true)
  end

  defp vapid_configured? do
    present?(Application.get_env(:web_push_elixir, :vapid_public_key)) and
      present?(Application.get_env(:web_push_elixir, :vapid_private_key))
  end

  defp present?(value), do: is_binary(value) and value != ""

  @doc "The VAPID public key to hand the browser, or `nil` when unconfigured."
  @spec vapid_public_key() :: String.t() | nil
  def vapid_public_key do
    case Application.get_env(:web_push_elixir, :vapid_public_key) do
      key when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  @doc """
  Stores (or refreshes) a subscription for `user`.

  `attrs` is the browser's `PushSubscription.toJSON()` map plus an optional
  `"user_agent"`. Re-subscribing the same endpoint updates the existing row,
  reassigning it to `user` if it moved between accounts on a shared device.
  """
  @spec subscribe(User.t(), map()) :: {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def subscribe(%User{} = user, attrs) do
    %Subscription{user_id: user.id}
    |> Subscription.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:p256dh, :auth, :user_agent, :user_id, :updated_at]},
      conflict_target: :endpoint
    )
  end

  @doc "Removes the subscription for `endpoint`, if any. Always returns `:ok`."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(endpoint) when is_binary(endpoint) do
    Repo.delete_all(from s in Subscription, where: s.endpoint == ^endpoint)
    :ok
  end

  @doc "All subscriptions belonging to the given users."
  @spec list_for_users([User.t() | integer()]) :: [Subscription.t()]
  def list_for_users(users) do
    ids = Enum.map(users, &user_id/1)

    Repo.all(from s in Subscription, where: s.user_id in ^ids)
  end

  defp user_id(%User{id: id}), do: id
  defp user_id(id) when is_integer(id), do: id

  @doc """
  Sends `payload` to every subscription `user` has.

  `payload` is a map with at least `:title` and `:body`, optionally `:url`
  (a path the notification click should open) and `:tag` (collapses repeats).
  Returns `{:ok, %{sent: n, pruned: n, failed: n}}`; `{:ok, %{...}}` with all
  zeros when push is disabled. Dead subscriptions (404/410) are deleted.
  """
  @spec deliver(User.t(), map(), keyword()) :: {:ok, map()}
  def deliver(%User{} = user, payload, _opts \\ []) when is_map(payload) do
    if enabled?() do
      message = encode(payload)

      stats =
        [user]
        |> list_for_users()
        |> Enum.reduce(%{sent: 0, pruned: 0, failed: 0}, fn sub, acc ->
          case Sender.impl().deliver(to_client_shape(sub), message) do
            {:ok, _} ->
              %{acc | sent: acc.sent + 1}

            {:error, :expired} ->
              Repo.delete(sub)
              %{acc | pruned: acc.pruned + 1}

            {:error, reason} ->
              Logger.warning("web push to subscription #{sub.id} failed: #{inspect(reason)}")
              %{acc | failed: acc.failed + 1}
          end
        end)

      {:ok, stats}
    else
      {:ok, %{sent: 0, pruned: 0, failed: 0}}
    end
  end

  @doc """
  Enqueues delivery of `payload` to each of `user`'s subscriptions as its own
  `Trygg.Push.DeliveryWorker` job, so a dead or slow endpoint retries (or is
  pruned) on its own without blocking the others or re-sending to the ones
  that already succeeded.

  Prefer this over `deliver/3` from request, LiveView, or job code that
  shouldn't block on push-service HTTP. A quiet no-op (`:ok`) when push is
  disabled or the user has no subscriptions.
  """
  @spec enqueue(User.t(), map()) :: :ok
  def enqueue(%User{} = user, payload) when is_map(payload) do
    if enabled?() do
      args = payload_args(payload)

      [user]
      |> list_for_users()
      |> Enum.map(&DeliveryWorker.new(%{subscription_id: &1.id, payload: args}))
      |> Oban.insert_all()
    end

    :ok
  end

  @doc """
  Delivers `payload` to a single subscription by id. Called by
  `Trygg.Push.DeliveryWorker`.

  Returns `:ok` when sent, when the subscription is already gone, or when the
  push service reports it expired (the row is pruned). Returns
  `{:error, reason}` on a transient failure so the job retries — retries are
  scoped to this one subscription because a Web Push POST is not idempotent.
  """
  @spec deliver_one(integer(), map()) :: :ok | {:error, term()}
  def deliver_one(subscription_id, payload) when is_map(payload) do
    with true <- enabled?(),
         %Subscription{} = sub <- Repo.get(Subscription, subscription_id) do
      case Sender.impl().deliver(to_client_shape(sub), encode(payload)) do
        {:ok, _} ->
          :ok

        {:error, :expired} ->
          Repo.delete(sub)
          :ok

        {:error, reason} ->
          Logger.warning("web push to subscription #{sub.id} failed: #{inspect(reason)}")
          {:error, reason}
      end
    else
      false -> :ok
      nil -> :ok
    end
  end

  defp to_client_shape(%Subscription{} = sub) do
    %{"endpoint" => sub.endpoint, "keys" => %{"p256dh" => sub.p256dh, "auth" => sub.auth}}
  end

  # Trim to the delivery keys and stringify so the args round-trip through
  # JSON unchanged between `enqueue/2` and the worker's `perform/1`.
  defp payload_args(payload) do
    payload
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.take(~w(title body url tag))
  end

  # Accepts atom- or string-keyed payloads (the synchronous path passes atoms,
  # the worker path passes strings after the JSON round-trip).
  defp encode(payload), do: payload |> payload_args() |> Jason.encode!()
end
