defmodule Trygg.Families do
  @moduledoc """
  Families, their children, the caregivers who share them, and pending
  caregiver invites.

  A `Trygg.Families.Family` is the group of caregivers that shares one or more
  children; roles are held by the family (`Trygg.Families.Membership`), so a
  caregiver sees all of its children.

  Every public function takes a `%Trygg.Accounts.Scope{}` as its first argument
  and authorizes the caller through their membership of the child's family.
  Roles form a hierarchy: `:owner` > `:caregiver` > `:viewer`. A scope that came
  in on an API token (`scope.api_token`) is further confined to the token's
  family and can never rise above the token's role, which is never `:owner`.
  """

  import Ecto.Query, warn: false

  alias Trygg.Repo
  alias Trygg.Accounts
  alias Trygg.Accounts.{Scope, User}
  alias Trygg.Families.{ApiToken, Child, Family, Membership, Invite, FamilyNotifier}

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

  # People and invites belong to the family, so a change to them is announced
  # on the topic of each of its children, as `{tag, child_id}`: whichever child
  # someone happens to have open hears about it.
  defp broadcast_family(family_id, tag) do
    Enum.each(child_ids(family_id), &broadcast(&1, {tag, &1}))
  end

  # Tell every current member of a family that the set of children they can see
  # changed (a child added, renamed, deleted, or a membership/role change).
  # Delivered as `{:children_changed, user_id}` on each member's private
  # `Trygg.Accounts` topic, which LiveViews subscribe to via
  # `Accounts.subscribe_user/1`. `also` carries extra user ids that were
  # members a moment ago (someone just removed, or the family about to lose its
  # last child).
  defp broadcast_children_changed(family_id, also \\ []) do
    (member_user_ids(family_id) ++ also)
    |> Enum.uniq()
    |> Enum.each(&Accounts.broadcast_user(&1, {:children_changed, &1}))
  end

  defp member_user_ids(family_id) do
    Repo.all(from m in Membership, where: m.family_id == ^family_id, select: m.user_id)
  end

  defp child_ids(family_id) do
    Repo.all(from c in Child, where: c.family_id == ^family_id, select: c.id)
  end

  # Child structs built from an id alone (`%Child{id: entry.child_id}`) don't
  # carry their family.
  defp family_id(%Child{family_id: family_id}) when not is_nil(family_id), do: family_id

  defp family_id(%Child{id: id}),
    do: Repo.one(from c in Child, where: c.id == ^id, select: c.family_id)

  ## Scoping --------------------------------------------------------------------

  # The memberships `scope` may act through. A browser session reaches every
  # family its user belongs to; an API token only the one it was issued for.
  defp memberships_for(%Scope{user: %User{id: user_id}, api_token: token}) do
    query = from m in Membership, where: m.user_id == ^user_id

    case token do
      nil -> query
      %ApiToken{family_id: family_id} -> from m in query, where: m.family_id == ^family_id
    end
  end

  # An API token never carries more than its own role, whatever its issuer is.
  defp cap_role(%Scope{api_token: %ApiToken{role: max}}, role), do: lower_role(role, max)
  defp cap_role(%Scope{}, role), do: role

  defp lower_role(a, b), do: if(@role_rank[a] <= @role_rank[b], do: a, else: b)

  ## Children -----------------------------------------------------------------

  @doc """
  Lists the children the user can see, most recently added first, with the
  user's `:role` for each populated.
  """
  def list_children(%Scope{user: %User{}} = scope) do
    from(c in Child,
      join: m in ^memberships_for(scope),
      on: m.family_id == c.family_id,
      order_by: [desc: c.inserted_at],
      select: %{c | role: m.role}
    )
    |> Repo.all()
    |> Enum.map(&%{&1 | role: cap_role(scope, &1.role)})
  end

  @doc """
  The families the user owns, newest first, with their `:children` preloaded —
  the ones a new child can be added to.
  """
  def list_owned_families(%Scope{user: %User{}} = scope) do
    from(f in Family,
      join: m in ^memberships_for(scope),
      on: m.family_id == f.id and m.role == :owner,
      order_by: [desc: f.id],
      preload: [:children]
    )
    |> Repo.all()
  end

  @doc """
  Fetches a child the user is a member of, with `:role` populated.

  Raises `Ecto.NoResultsError` if the child does not exist or the user is not
  a member — callers treat both cases as "not found".
  """
  def get_child!(%Scope{user: %User{}} = scope, id) do
    child =
      from(c in Child,
        join: m in ^memberships_for(scope),
        on: m.family_id == c.family_id,
        where: c.id == ^id,
        select: %{c | role: m.role}
      )
      |> Repo.one!()

    %{child | role: cap_role(scope, child.role)}
  end

  @doc "Returns an `%Ecto.Changeset{}` for tracking child changes."
  def change_child(%Child{} = child, attrs \\ %{}) do
    Child.changeset(child, attrs)
  end

  @doc """
  Creates a child, atomically.

  By default the child starts a new family with the current user as its owner.
  Pass `family_id: id` to add it to a family the user already owns instead, so
  its other caregivers see it too (raises `Trygg.Families.NotAuthorizedError`
  unless the user is an owner of that family). Not available to API tokens.
  """
  def create_child(scope, attrs, opts \\ [])

  def create_child(%Scope{api_token: %ApiToken{role: role}}, _attrs, _opts),
    do: raise(Trygg.Families.NotAuthorizedError, role: role, required: :owner)

  def create_child(%Scope{user: %User{id: user_id}} = scope, attrs, opts) do
    existing_family_id = opts[:family_id]
    if existing_family_id, do: authorize_family!(scope, existing_family_id, :owner)

    result =
      Repo.transact(fn ->
        with {:ok, family_id} <- ensure_family(existing_family_id, user_id),
             {:ok, child} <-
               %Child{family_id: family_id} |> Child.changeset(attrs) |> Repo.insert() do
          {:ok, %{child | role: :owner}}
        end
      end)

    with {:ok, child} <- result do
      broadcast_children_changed(child.family_id)
      {:ok, child}
    end
  end

  defp ensure_family(nil, user_id) do
    with {:ok, family} <- Repo.insert(%Family{}),
         {:ok, _membership} <-
           %Membership{family_id: family.id, user_id: user_id}
           |> Membership.changeset(%{role: :owner})
           |> Repo.insert() do
      {:ok, family.id}
    end
  end

  defp ensure_family(family_id, _user_id), do: {:ok, family_id}

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

      broadcast_children_changed(updated.family_id)
      {:ok, updated}
    end
  end

  @doc """
  Sets which trackers the child's Home screen shows (`Child.tracked_types/0`).
  Unlike `update_child/3` this only needs the `:caregiver` role, so anyone who
  logs for the child can shape what everyone sees. Touches nothing else.
  """
  def update_tracked_types(%Scope{} = scope, %Child{} = child, types) do
    role = authorize!(scope, child, :caregiver)

    with {:ok, updated} <- child |> Child.changeset(%{tracked_types: types}) |> Repo.update() do
      updated = %{updated | role: role}
      broadcast(child.id, {:child_updated, updated})
      broadcast_children_changed(updated.family_id)
      {:ok, updated}
    end
  end

  # Keep `birth_date` and `expected_birth_date` mutually exclusive so
  # `expecting?/1` stays a clean function of `birth_date` alone.
  defp reconcile_practice_mode(child, attrs, true = _was_expecting?) do
    changeset = Child.changeset(child, attrs)

    # Confirming a birth date ends the wait. The due date goes, but first it
    # tells us how early (or late) the baby came, unless the owner said.
    if Ecto.Changeset.get_field(changeset, :birth_date) do
      changeset
      |> derive_gestational_age()
      |> Ecto.Changeset.put_change(:expected_birth_date, nil)
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
      |> Ecto.Changeset.put_change(:gestational_age_days, nil)
    else
      changeset
    end
  end

  defp derive_gestational_age(changeset) do
    if Ecto.Changeset.get_field(changeset, :gestational_age_days) do
      changeset
    else
      birth = Ecto.Changeset.get_field(changeset, :birth_date)
      due = Ecto.Changeset.get_field(changeset, :expected_birth_date)

      case Child.gestational_age_from_due_date(birth, due) do
        nil -> changeset
        days -> Ecto.Changeset.put_change(changeset, :gestational_age_days, days)
      end
    end
  end

  defp purge_practice_data(child_id) do
    Repo.delete_all(from e in Trygg.Log.Entry, where: e.child_id == ^child_id)
    Repo.delete_all(from m in Trygg.Growth.Measurement, where: m.child_id == ^child_id)
    :ok
  end

  @doc """
  Deletes a child and everything logged for it. Requires the `:owner` role.

  A family left without children goes with it, along with its caregivers,
  invites and API tokens.
  """
  def delete_child(%Scope{} = scope, %Child{} = child) do
    authorize!(scope, child, :owner)
    members = member_user_ids(child.family_id)

    result =
      Repo.transact(fn ->
        with {:ok, deleted} <- Repo.delete(child) do
          delete_family_if_empty(child.family_id)
          {:ok, deleted}
        end
      end)

    with {:ok, deleted} <- result do
      broadcast(child.id, {:child_deleted, child.id})
      broadcast_children_changed(child.family_id, members)
      {:ok, deleted}
    end
  end

  defp delete_family_if_empty(family_id) do
    unless Repo.exists?(from c in Child, where: c.family_id == ^family_id) do
      Repo.delete_all(from f in Family, where: f.id == ^family_id)
    end

    :ok
  end

  ## Roles / authorization --------------------------------------------------

  @doc """
  Returns the user's role for the child (through its family), or `nil` if they
  are not a member. For an API token this is capped at the token's role.
  """
  def member_role(%Scope{user: %User{}} = scope, %Child{id: child_id}) do
    from(m in memberships_for(scope),
      join: c in Child,
      on: c.family_id == m.family_id,
      where: c.id == ^child_id,
      select: m.role
    )
    |> Repo.one()
    |> capped(scope)
  end

  @doc "Like `member_role/2`, for a family."
  def family_role(%Scope{user: %User{}} = scope, family_id) do
    from(m in memberships_for(scope), where: m.family_id == ^family_id, select: m.role)
    |> Repo.one()
    |> capped(scope)
  end

  defp capped(nil, _scope), do: nil
  defp capped(role, scope), do: cap_role(scope, role)

  @doc """
  Ensures the user's role for the child is at least `min_role`, returning the
  role. Raises `Trygg.Families.NotAuthorizedError` otherwise.
  """
  def authorize!(%Scope{} = scope, %Child{} = child, min_role) do
    scope |> member_role(child) |> check!(min_role)
  end

  @doc "Like `authorize!/3`, for a family."
  def authorize_family!(%Scope{} = scope, family_id, min_role) do
    scope |> family_role(family_id) |> check!(min_role)
  end

  defp check!(role, min_role) do
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

  @doc """
  Lists the caregivers of a child's family (memberships preloaded with `:user`).
  """
  def list_members(%Scope{} = scope, %Child{} = child) do
    authorize!(scope, child, :viewer)

    from(m in Membership,
      where: m.family_id == ^family_id(child),
      order_by: [asc: m.inserted_at],
      preload: [:user]
    )
    |> Repo.all()
  end

  @doc "Removes a caregiver. Requires `:owner`; refuses to remove the last owner."
  def remove_member(%Scope{} = scope, %Child{} = child, %Membership{} = membership) do
    authorize!(scope, child, :owner)
    family_id = family_id(child)

    cond do
      membership.family_id != family_id ->
        {:error, :not_found}

      membership.role == :owner and owner_count(family_id) <= 1 ->
        {:error, :last_owner}

      true ->
        result =
          Repo.transact(fn ->
            with {:ok, deleted} <- Repo.delete(membership) do
              # Their API tokens act as them, so they go too.
              Repo.delete_all(
                from t in ApiToken,
                  where: t.family_id == ^family_id and t.created_by_id == ^membership.user_id
              )

              {:ok, deleted}
            end
          end)

        with {:ok, deleted} <- result do
          broadcast_family(family_id, :members_changed)
          broadcast_children_changed(family_id, [membership.user_id])
          {:ok, deleted}
        end
    end
  end

  @doc "Changes a caregiver's role. Requires `:owner`; keeps at least one owner."
  def update_member_role(%Scope{} = scope, %Child{} = child, %Membership{} = membership, role) do
    authorize!(scope, child, :owner)
    family_id = family_id(child)

    cond do
      membership.family_id != family_id ->
        {:error, :not_found}

      membership.role == :owner and role != :owner and owner_count(family_id) <= 1 ->
        {:error, :last_owner}

      true ->
        with {:ok, updated} <-
               membership |> Membership.changeset(%{role: role}) |> Repo.update() do
          broadcast_family(family_id, :members_changed)
          broadcast_children_changed(family_id)
          {:ok, updated}
        end
    end
  end

  defp owner_count(family_id) do
    Repo.one(
      from m in Membership,
        where: m.family_id == ^family_id and m.role == :owner,
        select: count(m.id)
    )
  end

  ## Invites -------------------------------------------------------------------

  @doc "Lists the still-open invites to a child's family. Requires `:owner`."
  def list_invites(%Scope{} = scope, %Child{} = child) do
    authorize!(scope, child, :owner)

    from(i in Invite,
      where:
        i.family_id == ^family_id(child) and is_nil(i.accepted_at) and
          i.expires_at > ^DateTime.utc_now(),
      order_by: [desc: i.inserted_at]
    )
    |> Repo.all()
  end

  @doc "Returns an `%Ecto.Changeset{}` for a new invite form."
  def change_invite(attrs \\ %{}) do
    Invite.changeset(%Invite{}, attrs)
  end

  @doc """
  Creates an invite for `email` to the child's family and emails them a link.
  They get access to every child in the family.

  `url_fun` receives the invite token and returns the acceptance URL. Requires
  `:owner`. Returns `{:error, :already_member}` if the email already belongs to
  a caregiver of the family.
  """
  def invite_caregiver(%Scope{} = scope, %Child{} = child, attrs, url_fun)
      when is_function(url_fun, 1) do
    authorize!(scope, child, :owner)

    family_id = family_id(child)

    changeset =
      Invite.changeset(%Invite{family_id: family_id, invited_by_id: scope.user.id}, attrs)

    with {:ok, email} <- fetch_change_email(changeset),
         :ok <- ensure_not_member(family_id, email),
         {:ok, invite} <- Repo.insert(changeset) do
      FamilyNotifier.deliver_caregiver_invite(
        invite,
        family_label(family_id),
        scope.user,
        url_fun.(invite.token)
      )

      broadcast_family(family_id, :invites_changed)
      {:ok, invite}
    end
  end

  defp fetch_change_email(changeset) do
    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, invite} -> {:ok, invite.email}
      {:error, cs} -> {:error, cs}
    end
  end

  defp ensure_not_member(family_id, email) do
    exists? =
      Repo.exists?(
        from m in Membership,
          join: u in User,
          on: u.id == m.user_id,
          where: m.family_id == ^family_id and fragment("lower(?)", u.email) == ^email
      )

    if exists?, do: {:error, :already_member}, else: :ok
  end

  defp family_label(family_id) do
    Family |> Repo.get!(family_id) |> Repo.preload(:children) |> Family.label()
  end

  @doc """
  Fetches an open invite by token, preloaded with its `:family` (and that
  family's `:children`) and `:invited_by`.
  """
  def get_pending_invite(token) when is_binary(token) do
    Invite
    |> Repo.get_by(token: token)
    |> Repo.preload([[family: :children], :invited_by])
    |> case do
      %Invite{} = invite -> if Invite.pending?(invite), do: invite, else: nil
      nil -> nil
    end
  end

  @doc "Revokes (deletes) a pending invite. Requires `:owner`."
  def revoke_invite(%Scope{} = scope, %Invite{} = invite) do
    authorize_family!(scope, invite.family_id, :owner)

    with {:ok, deleted} <- Repo.delete(invite) do
      broadcast_family(invite.family_id, :invites_changed)
      {:ok, deleted}
    end
  end

  @doc """
  Accepts the invite identified by `token` for the current user.

  Returns `{:ok, child}` on success — the family's oldest child, with `:role`
  populated, as somewhere to land — or `{:error, reason}` where reason is
  `:not_found`, `:email_mismatch`. If the user is already a member, the invite
  is marked accepted and their existing role is returned.
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
            where: m.family_id == ^invite.family_id and m.user_id == ^user.id
        )

      with {:ok, membership} <- upsert_membership(existing, invite, user),
           {:ok, _invite} <-
             invite
             |> Ecto.Changeset.change(
               accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
             )
             |> Repo.update() do
        child =
          Repo.one!(
            from c in Child,
              where: c.family_id == ^invite.family_id,
              order_by: [asc: c.inserted_at, asc: c.id],
              limit: 1
          )

        broadcast_family(invite.family_id, :members_changed)
        broadcast_children_changed(invite.family_id)
        {:ok, %{child | role: membership.role}}
      end
    end)
  end

  defp upsert_membership(nil, invite, user) do
    %Membership{family_id: invite.family_id, user_id: user.id}
    |> Membership.changeset(%{role: invite.role})
    |> Repo.insert()
  end

  defp upsert_membership(%Membership{} = existing, _invite, _user), do: {:ok, existing}
end
