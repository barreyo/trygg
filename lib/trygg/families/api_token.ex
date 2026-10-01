defmodule Trygg.Families.ApiToken do
  @moduledoc """
  A bearer token that lets a script or integration call the REST API on behalf
  of a family.

  The token acts as the caregiver who issued it, but only within `family_id` and
  never with more than `role`, which is `:viewer` (read only) or `:caregiver`
  (can log). It is never `:owner`: managing children and people stays in the
  app. Only a SHA-256 of the secret is stored; the secret is shown once, when
  the token is created, in the virtual `:secret` field.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @roles [:viewer, :caregiver]
  @prefix "trygg_"

  schema "api_tokens" do
    field :name, :string
    field :role, Ecto.Enum, values: @roles, default: :viewer
    field :token_hash, :binary
    field :hint, :string
    field :last_used_at, :utc_datetime
    field :expires_at, :utc_datetime

    field :secret, :string, virtual: true

    belongs_to :family, Trygg.Families.Family
    belongs_to :created_by, Trygg.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "The roles a token can be given."
  def roles, do: @roles

  @doc "Prefix every secret starts with, so leaked ones are easy to spot and scan for."
  def prefix, do: @prefix

  @doc false
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:name, :role])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :role])
    |> validate_length(:name, max: 80)
  end

  @doc "Sets a fresh random secret on the token, along with the hash and hint stored for it."
  def put_secret(%Ecto.Changeset{} = changeset) do
    secret = @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    changeset
    |> put_change(:secret, secret)
    |> put_change(:token_hash, hash(secret))
    |> put_change(:hint, String.slice(secret, -4, 4))
  end

  @doc "The value stored for a secret."
  def hash(secret) when is_binary(secret), do: :crypto.hash(:sha256, secret)

  @doc "Whether the token has passed its expiry."
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) != :gt
end
