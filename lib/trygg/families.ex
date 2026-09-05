defmodule Trygg.Families do
  @moduledoc """
  Children, the caregivers who share them, and pending caregiver invites.

  Every public function takes a `%Trygg.Accounts.Scope{}` as its first argument
  and authorizes the caller through their `Trygg.Families.Membership` for the
  child. Roles form a hierarchy: `:owner` > `:caregiver` > `:viewer`.
  """

  import Ecto.Query, warn: false

  alias Trygg.Repo
  alias Trygg.Accounts
  alias Trygg.Accounts.{Scope, User}
  alias Trygg.Families.{Child, Membership, Invite, FamilyNotifier}

  @role_rank %{owner: 3, caregiver: 2, viewer: 1}

  ## PubSub -------------------------------------------------------------------

  @doc "Topic string for realtime messages about a child."
  def topic(child_id), do: "child:#{child_id}"

  @doc "Subscribe the calling process to realtime messages about a child."
  def subscribe(child_id) do
    Phoenix.PubSub.subscribe(Trygg.PubSub, topic(child_id))
  end

  @doc "Broadcast a realtime message to everyone watching a child."
  def broadcast(child_id, message) do
    Phoenix.PubSub.broadcast(Trygg.PubSub, topic(child_id), message)
  end

  # Tell every current member of a child that the set of children they can see
  # changed (a child added, renamed, deleted, or a membership/role change).
  # Delivered as `{:children_changed, user_id}` on each member's private
  # `Trygg.Accounts` topic, which LiveViews subscribe to via
  # `Accounts.subscribe_user/1`. `also` carries extra user ids that were
  # members a moment ago (someone just removed, or the child about to be
  # deleted).
  defp broadcast_children_changed(child_id, also \\ []) do
    (member_user_ids(child_id) ++ also)
    |> Enum.uniq()
    |> Enum.each(&Accounts.broadcast_user(&1, {:children_changed, &1}))
  end

  defp member_user_ids(child_id) do
    Repo.all(from m in Membership, where: m.child_id == ^child_id, select: m.user_id)
  end

  ## Children -----------------------------------------------------------------

  @doc """
  Lists the children the user can see, most recently added first, with the
  user's `:role` for each populated.
  """
  def list_children(%Scope{user: %User{id: user_id}}) do
    from(c in Child,
      join: m in Membership,
      on: m.child_id == c.id and m.user_id == ^user_id,
      order_by: [desc: c.inserted_at],
      select: %{c | role: m.role}
    )
    |> Repo.all()
  end

  @doc """
  Fetches a child the user is a member of, with `:role` populated.

  Raises `Ecto.NoResultsError` if the child does not exist or the user is not
  a member — callers treat both cases as "not found".
  """
  def get_child!(%Scope{user: %User{id: user_id}}, id) do
    from(c in Child,
      join: m in Membership,
      on: m.child_id == c.id and m.user_id == ^user_id,
      where: c.id == ^id,
      select: %{c | role: m.role}
    )
    |> Repo.one!()
  end

  @doc "Returns an `%Ecto.Changeset{}` for tracking child changes."
  def change_child(%Child{} = child, attrs \\ %{}) do
    Child.changeset(child, attrs)
  end

  @doc """
  Creates a child and makes the current user its owner, atomically.
  """
  def create_child(%Scope{user: %User{id: user_id}}, attrs) do
    result =
      Repo.transact(fn ->
        with {:ok, child} <- %Child{} |> Child.changeset(attrs) |> Repo.insert(),
             {:ok, _membership} <-
               %Membership{child_id: child.id, user_id: user_id, role: :owner}
               |> Membership.changeset(%{role: :owner})
               |> Repo.insert() do
          {:ok, %{child | role: :owner}}
        end
      end)

    with {:ok, child} <- result do
      broadcast_children_changed(child.id)
      {:ok, child}
    end
  end

  @doc """
  Updates a child. Requires the `:owner` role.

  Handles the "practice mode" transitions:

    * confirming a real `birth_date` on an expecting child ends the wait — the
      practice log (entries and growth measurements) is wiped in the same
      transaction and `{:child_born, child}` is broadcast.
    * setting an `expected_birth_date` on a born child puts them back into
      practice mode — the birth date is cleared and everyone's screens pick up
      the change via the usual `{:child_updated, child}`. Existing entries are
      left in place; they become practice data and go when the birth is next
      confirmed.
  """
  def update_child(%Scope{} = scope, %Child{} = child, attrs) do
    role = authorize!(scope, child, :owner)
    was_expecting? = Child.expecting?(child)

    result =
      Repo.transact(fn ->
        changeset = reconcile_practice_mode(child, attrs, was_expecting?)

        with {:ok, updated} <- Repo.update(changeset) do
          born? = was_expecting? and not Child.expecting?(updated)
          if born?, do: purge_practice_data(updated.id)
          {:ok, {%{updated | role: role}, born?}}
        end
      end)

    with {:ok, {updated, born?}} <- result do
      if born?,
        do: broadcast(child.id, {:child_born, updated}),
        else: broadcast(child.id, {:child_updated, updated})

      broadcast_children_changed(child.id)
      {:ok, updated}
    end
  end

  # Keep `birth_date` and `expected_birth_date` mutually exclusive so
  # `expecting?/1` stays a clean function of `birth_date` alone.
  defp reconcile_practice_mode(child, attrs, true = _was_expecting?) do
    changeset = Child.changeset(child, attrs)

    # Confirming a birth date ends the wait — the due date is now meaningless.
    if Ecto.Changeset.get_field(changeset, :birth_date) do
      Ecto.Changeset.put_change(changeset, :expected_birth_date, nil)
    else
      changeset
    end
  end

  defp reconcile_practice_mode(child, attrs, false = _was_expecting?) do
    changeset = Child.changeset(child, attrs)

    # Dropping a due date on a born child re-opens practice mode — clear the
    # confirmed birth date (and time) so they read as "expecting" again.
    if Ecto.Changeset.get_change(changeset, :expected_birth_date) do
      changeset
      |> Ecto.Changeset.put_change(:birth_date, nil)
      |> Ecto.Changeset.put_change(:birth_time, nil)
    else
      changeset
    end
  end

  defp purge_practice_data(child_id) do
    Repo.delete_all(from e in Trygg.Log.Entry, where: e.child_id == ^child_id)
    Repo.delete_all(from m in Trygg.Growth.Measurement, where: m.child_id == ^child_id)
    :ok
  end

  @doc "Deletes a child and everything logged for it. Requires the `:owner` role."
  def delete_child(%Scope{} = scope, %Child{} = child) do
    authorize!(scope, child, :owner)
    members = member_user_ids(child.id)

    with {:ok, deleted} <- Repo.delete(child) do
      broadcast(child.id, {:child_deleted, child.id})
      broadcast_children_changed(child.id, members)
      {:ok, deleted}
    end
  end

  ## Roles / authorization --------------------------------------------------

  @doc "Returns the user's role for the child, or `nil` if they are not a member."
  def member_role(%Scope{user: %User{id: user_id}}, %Child{id: child_id}) do
    Repo.one(
      from m in Membership,
        where: m.child_id == ^child_id and m.user_id == ^user_id,
        select: m.role
    )
  end

  @doc """
  Ensures the user's role for the child is at least `min_role`, returning the
  role. Raises `Trygg.Families.NotAuthorizedError` otherwise.
  """
  def authorize!(%Scope{} = scope, %Child{} = child, min_role) do
    role = member_role(scope, child)

    if role && @role_rank[role] >= @role_rank[min_role] do
      role
    else
      raise Trygg.Families.NotAuthorizedError, role: role, required: min_role
    end
  end

  @doc "Whether the user's role for the child is at least `min_role`."
  def can?(%Scope{} = scope, %Child{} = child, min_role) do
    role = scope.child && scope.child.id == child.id && scope.role

    role = role || member_role(scope, child)

    !!role && @role_rank[role] >= @role_rank[min_role]
  end

  ## Members ---------------------------------------------------------------

  @doc "Lists a child's caregivers (memberships preloaded with `:user`)."
  def list_members(%Scope{} = scope, %Child{} = child) do
    authorize!(scope, child, :viewer)

    from(m in Membership,
      where: m.child_id == ^child.id,
      order_by: [asc: m.inserted_at],
      preload: [:user]
    )
    |> Repo.all()
  end

  @doc "Removes a caregiver. Requires `:owner`; refuses to remove the last owner."
  def remove_member(%Scope{} = scope, %Child{} = child, %Membership{} = membership) do
    authorize!(scope, child, :owner)

    cond do
      membership.child_id != child.id ->
        {:error, :not_found}

      membership.role == :owner and owner_count(child) <= 1 ->
        {:error, :last_owner}

      true ->
        with {:ok, deleted} <- Repo.delete(membership) do
          broadcast(child.id, {:members_changed, child.id})
          broadcast_children_changed(child.id, [membership.user_id])
          {:ok, deleted}
        end
    end
  end

  @doc "Changes a caregiver's role. Requires `:owner`; keeps at least one owner."
  def update_member_role(%Scope{} = scope, %Child{} = child, %Membership{} = membership, role) do
    authorize!(scope, child, :owner)

    cond do
      membership.child_id != child.id ->
        {:error, :not_found}

      membership.role == :owner and role != :owner and owner_count(child) <= 1 ->
        {:error, :last_owner}

      true ->
        with {:ok, updated} <-
               membership |> Membership.changeset(%{role: role}) |> Repo.update() do
          broadcast(child.id, {:members_changed, child.id})
          broadcast_children_changed(child.id)
          {:ok, updated}
        end
    end
  end

  defp owner_count(%Child{id: child_id}) do
    Repo.one(
      from m in Membership,
        where: m.child_id == ^child_id and m.role == :owner,
        select: count(m.id)
    )
  end

  ## Invites -------------------------------------------------------------------

  @doc "Lists a child's still-open invites. Requires `:owner`."
  def list_invites(%Scope{} = scope, %Child{} = child) do
    authorize!(scope, child, :owner)

    from(i in Invite,
      where:
        i.child_id == ^child.id and is_nil(i.accepted_at) and i.expires_at > ^DateTime.utc_now(),
      order_by: [desc: i.inserted_at]
    )
    |> Repo.all()
  end

  @doc "Returns an `%Ecto.Changeset{}` for a new invite form."
  def change_invite(attrs \\ %{}) do
    Invite.changeset(%Invite{}, attrs)
  end

  @doc """
  Creates an invite for `email` and emails them a link.

  `url_fun` receives the invite token and returns the acceptance URL. Requires
  `:owner`. Returns `{:error, :already_member}` if the email already belongs to
  a caregiver of the child.
  """
  def invite_caregiver(%Scope{} = scope, %Child{} = child, attrs, url_fun)
      when is_function(url_fun, 1) do
    authorize!(scope, child, :owner)

    changeset = Invite.changeset(%Invite{child_id: child.id, invited_by_id: scope.user.id}, attrs)

    with {:ok, email} <- fetch_change_email(changeset),
         :ok <- ensure_not_member(child, email),
         {:ok, invite} <- Repo.insert(changeset) do
      FamilyNotifier.deliver_caregiver_invite(invite, child, scope.user, url_fun.(invite.token))
      broadcast(child.id, {:invites_changed, child.id})
      {:ok, invite}
    end
  end

  defp fetch_change_email(changeset) do
    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, invite} -> {:ok, invite.email}
      {:error, cs} -> {:error, cs}
    end
  end

  defp ensure_not_member(%Child{id: child_id}, email) do
    exists? =
      Repo.exists?(
        from m in Membership,
          join: u in User,
          on: u.id == m.user_id,
          where: m.child_id == ^child_id and fragment("lower(?)", u.email) == ^email
      )

    if exists?, do: {:error, :already_member}, else: :ok
  end

  @doc "Fetches an open invite by token, preloaded with `:child` and `:invited_by`."
  def get_pending_invite(token) when is_binary(token) do
    Invite
    |> Repo.get_by(token: token)
    |> Repo.preload([:child, :invited_by])
    |> case do
      %Invite{} = invite -> if Invite.pending?(invite), do: invite, else: nil
      nil -> nil
    end
  end

  @doc "Revokes (deletes) a pending invite. Requires `:owner`."
  def revoke_invite(%Scope{} = scope, %Invite{} = invite) do
    child = Repo.get!(Child, invite.child_id)
    authorize!(scope, child, :owner)

    with {:ok, deleted} <- Repo.delete(invite) do
      broadcast(child.id, {:invites_changed, child.id})
      {:ok, deleted}
    end
  end

  @doc """
  Accepts the invite identified by `token` for the current user.

  Returns `{:ok, child}` (with `:role` populated) on success, or `{:error,
  reason}` where reason is `:not_found`, `:email_mismatch`. If the user is
  already a member, the invite is marked accepted and their existing role is
  returned.
  """
  def accept_invite(%Scope{user: %User{} = user}, token) do
    case get_pending_invite(token) do
      nil ->
        {:error, :not_found}

      %Invite{} = invite ->
        if String.downcase(user.email) == invite.email do
          do_accept_invite(user, invite)
        else
          {:error, :email_mismatch}
        end
    end
  end

  defp do_accept_invite(user, invite) do
    Repo.transact(fn ->
      existing =
        Repo.one(
          from m in Membership,
            where: m.child_id == ^invite.child_id and m.user_id == ^user.id
        )

      with {:ok, membership} <- upsert_membership(existing, invite, user),
           {:ok, _invite} <-
             invite
             |> Ecto.Changeset.change(
               accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
             )
             |> Repo.update() do
        child = Repo.get!(Child, invite.child_id)
        broadcast(child.id, {:members_changed, child.id})
        broadcast_children_changed(child.id)
        {:ok, %{child | role: membership.role}}
      end
    end)
  end

  defp upsert_membership(nil, invite, user) do
    %Membership{child_id: invite.child_id, user_id: user.id}
    |> Membership.changeset(%{role: invite.role})
    |> Repo.insert()
  end

  defp upsert_membership(%Membership{} = existing, _invite, _user), do: {:ok, existing}
end
