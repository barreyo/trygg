defmodule Trygg.FamiliesFixtures do
  @moduledoc """
  Test helpers for creating children, memberships and invites.
  """

  alias Trygg.Families
  alias Trygg.Repo

  import Trygg.AccountsFixtures

  def valid_child_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "Baby #{System.unique_integer([:positive])}",
      birth_date: Date.add(Date.utc_today(), -20),
      sex: :unspecified,
      timezone: "Etc/UTC"
    })
  end

  @doc "Creates a child owned by `scope` (a scope is created if not given)."
  def child_fixture(scope \\ nil, attrs \\ %{}) do
    scope = scope || user_scope_fixture()
    {:ok, child} = Families.create_child(scope, valid_child_attributes(attrs))
    child
  end

  @doc "Adds `user` to `child` with `role` and returns the membership."
  def membership_fixture(child, user, role \\ :caregiver) do
    %Trygg.Families.Membership{child_id: child.id, user_id: user.id}
    |> Trygg.Families.Membership.changeset(%{role: role})
    |> Repo.insert!()
  end

  @doc """
  Creates a child plus a second caregiver. Returns
  `%{owner_scope, child, member, member_scope}`.
  """
  def shared_child_fixture(role \\ :caregiver) do
    owner_scope = user_scope_fixture()
    child = child_fixture(owner_scope)
    member = user_fixture()
    membership_fixture(child, member, role)

    %{
      owner_scope: owner_scope,
      child: child,
      member: member,
      member_scope: user_scope_fixture(member)
    }
  end

  @doc "Creates a pending invite for `email` on `child`. Requires an owner scope."
  def invite_fixture(scope, child, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{email: unique_user_email(), role: :caregiver})

    {:ok, invite} =
      Families.invite_caregiver(scope, child, attrs, fn t -> "http://x/invites/#{t}" end)

    invite
  end
end
