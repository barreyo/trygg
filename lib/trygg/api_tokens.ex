defmodule Trygg.ApiTokens do
  @moduledoc """
  Family-wide API tokens: bearer secrets that let a script or integration call
  the REST API for a family.

  A token is issued by one caregiver and acts as them, inside the one family it
  was issued for. It carries a role of its own (`:viewer` or `:caregiver`) and is
  further limited to whatever its issuer can do right now: demote them and the
  token drops with them, remove them from the family and the token stops
  working (and is deleted). See `Trygg.Families.ApiToken`.
  """

  import Ecto.Query, warn: false

  alias Trygg.Accounts.Scope
  alias Trygg.Families
  alias Trygg.Families.ApiToken
  alias Trygg.Repo

  # Don't write `last_used_at` on every request; hourly is plenty to tell a
  # live token from a forgotten one.
  @last_used_granularity_seconds 3600

  @expiry_choices [30, 90, 365]

  @doc "Days a token can be set to live for. `nil` (no expiry) is always allowed too."
  def expiry_choices, do: @expiry_choices

  @doc "Returns an `%Ecto.Changeset{}` for a new token form."
  def change_token(attrs \\ %{}), do: ApiToken.changeset(%ApiToken{}, attrs)

  @doc """
  Lists the tokens of a family, newest first, with `:created_by` preloaded.
  Caregivers see the tokens they issued; owners see everyone's.
  """
  def list_tokens(%Scope{} = scope, family_id) do
    role = Families.authorize_family!(scope, family_id, :viewer)
    query = from t in ApiToken, where: t.family_id == ^family_id

    query =
      if role == :owner,
        do: query,
        else: from(t in query, where: t.created_by_id == ^scope.user.id)

    query |> order_by(desc: :id) |> preload(:created_by) |> Repo.all()
  end

  @doc """
  Issues a token for the family. Any member can; the token's role may not exceed
  the issuer's own. `attrs` takes `"name"`, `"role"` and an optional
  `"expires_in_days"` (one of `expiry_choices/0`).

  Returns `{:ok, token}` with the one-time `token.secret` set, or `{:error,
  changeset}`. API tokens can't issue tokens.
  """
  def create_token(%Scope{api_token: %ApiToken{role: role}}, _family_id, _attrs),
    do: raise(Families.NotAuthorizedError, role: role, required: :owner)

  def create_token(%Scope{} = scope, family_id, attrs) do
    issuer_role = Families.authorize_family!(scope, family_id, :viewer)
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    %ApiToken{family_id: family_id, created_by_id: scope.user.id}
    |> ApiToken.changeset(attrs)
    |> validate_role_within(issuer_role)
    |> put_expiry(attrs["expires_in_days"])
    |> ApiToken.put_secret()
    |> Repo.insert()
  end

  defp validate_role_within(changeset, :viewer) do
    if Ecto.Changeset.get_field(changeset, :role) == :caregiver do
      Ecto.Changeset.add_error(changeset, :role, "can't be more than your own access")
    else
      changeset
    end
  end

  defp validate_role_within(changeset, _issuer_role), do: changeset

  defp put_expiry(changeset, days) do
    case parse_days(days) do
      nil ->
        changeset

      days when days in @expiry_choices ->
        expires_at = DateTime.utc_now() |> DateTime.add(days, :day) |> DateTime.truncate(:second)
        Ecto.Changeset.put_change(changeset, :expires_at, expires_at)

      _ ->
        Ecto.Changeset.add_error(changeset, :expires_in_days, "isn't a valid choice")
    end
  end

  defp parse_days(days) when days in [nil, ""], do: nil
  defp parse_days(days) when is_integer(days), do: days

  defp parse_days(days) when is_binary(days) do
    case Integer.parse(days) do
      {int, ""} -> int
      _ -> :invalid
    end
  end

  defp parse_days(_), do: :invalid

  @doc """
  Revokes a token. The issuer can revoke their own; owners can revoke anyone's.
  """
  def revoke_token(%Scope{} = scope, %ApiToken{} = token) do
    role = Families.authorize_family!(scope, token.family_id, :viewer)

    if role == :owner or token.created_by_id == scope.user.id do
      Repo.delete(token)
    else
      raise Families.NotAuthorizedError, role: role, required: :owner
    end
  end

  @doc "Fetches a token of the family by id, as `list_tokens/2` would show it."
  def get_token!(%Scope{} = scope, family_id, id) do
    scope |> list_tokens(family_id) |> Enum.find(&(&1.id == id)) ||
      raise Ecto.NoResultsError, queryable: ApiToken
  end

  @doc """
  Resolves a secret from an `Authorization: Bearer` header to the scope it
  grants: the issuer, confined to the token's family and role.

  `:error` for an unknown, expired or orphaned secret (its issuer has left the
  family) alike, so callers can't tell which.
  """
  def authenticate(secret) when is_binary(secret) do
    query =
      from t in ApiToken,
        join: u in assoc(t, :created_by),
        join: m in Trygg.Families.Membership,
        on: m.family_id == t.family_id and m.user_id == t.created_by_id,
        where: t.token_hash == ^ApiToken.hash(secret),
        select: {t, u}

    with {%ApiToken{} = token, user} <- Repo.one(query),
         false <- ApiToken.expired?(token) do
      touch(token)
      {:ok, Scope.for_api_token(user, token)}
    else
      _ -> :error
    end
  end

  def authenticate(_), do: :error

  defp touch(%ApiToken{id: id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    stale = DateTime.add(now, -@last_used_granularity_seconds)

    Repo.update_all(
      from(t in ApiToken,
        where: t.id == ^id and (is_nil(t.last_used_at) or t.last_used_at < ^stale)
      ),
      set: [last_used_at: now]
    )

    :ok
  end
end
