defmodule Trygg.Push.Subscription do
  @moduledoc """
  One browser Push API subscription for a user. A user may have several — one
  per installed device / browser profile.

  `endpoint` is the push service URL the browser handed us; `p256dh` and
  `auth` are the client's public key and shared secret used to encrypt the
  payload. `endpoint` is unique: a device that re-subscribes updates its row.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "push_subscriptions" do
    field :endpoint, :string
    field :p256dh, :string
    field :auth, :string
    field :user_agent, :string

    belongs_to :user, Trygg.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset from a browser `PushSubscription.toJSON()` shape:

      %{"endpoint" => "...", "keys" => %{"p256dh" => "...", "auth" => "..."}}

  `user_id` is set by the caller, never cast.
  """
  def changeset(subscription, attrs) do
    attrs = normalize(attrs)

    subscription
    |> cast(attrs, [:endpoint, :p256dh, :auth, :user_agent])
    |> validate_required([:endpoint, :p256dh, :auth])
    |> validate_length(:endpoint, max: 2048)
    |> validate_length(:user_agent, max: 512)
    |> unique_constraint(:endpoint)
  end

  defp normalize(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    keys = Map.new(Map.get(attrs, "keys", %{}), fn {k, v} -> {to_string(k), v} end)

    attrs
    |> Map.put_new("p256dh", keys["p256dh"])
    |> Map.put_new("auth", keys["auth"])
  end
end
