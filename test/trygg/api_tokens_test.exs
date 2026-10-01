defmodule Trygg.ApiTokensTest do
  use Trygg.DataCase, async: true

  alias Trygg.{ApiTokens, Families}
  alias Trygg.Accounts.Scope
  alias Trygg.Families.{ApiToken, Membership}

  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  defp token_fixture(scope, family_id, attrs \\ %{}) do
    {:ok, token} =
      ApiTokens.create_token(
        scope,
        family_id,
        Enum.into(attrs, %{name: "Home", role: :caregiver})
      )

    token
  end

  defp token_scope(token) do
    {:ok, scope} = ApiTokens.authenticate(token.secret)
    scope
  end

  describe "create_token/3" do
    test "returns the secret once and stores only its hash" do
      %{owner_scope: owner, child: child} = shared_child_fixture()

      assert {:ok, token} =
               ApiTokens.create_token(owner, child.family_id, %{name: " Home ", role: :caregiver})

      assert "trygg_" <> _ = token.secret
      assert token.name == "Home"
      assert token.hint == String.slice(token.secret, -4, 4)
      assert token.token_hash == ApiToken.hash(token.secret)
      assert [listed] = ApiTokens.list_tokens(owner, child.family_id)
      assert listed.secret == nil
      refute inspect(Repo.all(ApiToken)) =~ token.secret
    end

    test "validates the name and role" do
      %{owner_scope: owner, child: child} = shared_child_fixture()

      assert {:error, changeset} =
               ApiTokens.create_token(owner, child.family_id, %{name: "", role: "owner"})

      assert %{name: _, role: _} = errors_on(changeset)
    end

    test "any member can issue one, but not above their own role" do
      %{child: child, member_scope: viewer} = shared_child_fixture(:viewer)

      assert {:ok, %{role: :viewer}} =
               ApiTokens.create_token(viewer, child.family_id, %{name: "Read", role: :viewer})

      assert {:error, changeset} =
               ApiTokens.create_token(viewer, child.family_id, %{name: "Write", role: :caregiver})

      assert %{role: ["can't be more than your own access"]} = errors_on(changeset)
    end

    test "non-members can't issue one" do
      %{child: child} = shared_child_fixture()

      assert_raise Families.NotAuthorizedError, fn ->
        ApiTokens.create_token(user_scope_fixture(), child.family_id, %{name: "x", role: :viewer})
      end
    end

    test "an API token can't issue tokens" do
      %{owner_scope: owner, child: child} = shared_child_fixture()
      scope = owner |> token_fixture(child.family_id) |> token_scope()

      assert_raise Families.NotAuthorizedError, fn ->
        ApiTokens.create_token(scope, child.family_id, %{name: "x", role: :viewer})
      end
    end

    test "supports an expiry from the offered choices" do
      %{owner_scope: owner, child: child} = shared_child_fixture()

      assert {:ok, token} =
               ApiTokens.create_token(owner, child.family_id, %{
                 name: "x",
                 role: :viewer,
                 expires_in_days: "30"
               })

      assert DateTime.diff(token.expires_at, DateTime.utc_now(), :day) in 29..30

      assert {:error, changeset} =
               ApiTokens.create_token(owner, child.family_id, %{
                 name: "x",
                 role: :viewer,
                 expires_in_days: "7"
               })

      assert %{expires_in_days: _} = errors_on(changeset)
    end
  end

  describe "authenticate/1" do
    test "returns a scope for the issuer, confined to the token" do
      %{owner_scope: owner, child: child} = shared_child_fixture()
      token = token_fixture(owner, child.family_id)

      assert {:ok, %Scope{user: user, api_token: %ApiToken{id: id}}} =
               ApiTokens.authenticate(token.secret)

      assert user.id == owner.user.id
      assert id == token.id
    end

    test "rejects unknown, malformed and expired secrets" do
      %{owner_scope: owner, child: child} = shared_child_fixture()
      token = token_fixture(owner, child.family_id)

      assert :error = ApiTokens.authenticate("trygg_nope")
      assert :error = ApiTokens.authenticate("")
      assert :error = ApiTokens.authenticate(nil)

      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
      Repo.update_all(ApiToken, set: [expires_at: past])
      assert :error = ApiTokens.authenticate(token.secret)
    end

    test "records last use, at most once an hour" do
      %{owner_scope: owner, child: child} = shared_child_fixture()
      token = token_fixture(owner, child.family_id)

      assert Repo.reload!(token).last_used_at == nil
      {:ok, _} = ApiTokens.authenticate(token.secret)
      first = Repo.reload!(token).last_used_at
      assert first

      earlier = DateTime.add(first, -10, :second)
      Repo.update_all(ApiToken, set: [last_used_at: earlier])
      {:ok, _} = ApiTokens.authenticate(token.secret)
      assert Repo.reload!(token).last_used_at == earlier
    end

    test "stops working once the issuer leaves the family, and the token is deleted" do
      %{owner_scope: owner, child: child, member: member, member_scope: member_scope} =
        shared_child_fixture()

      token = token_fixture(member_scope, child.family_id)
      membership = Repo.get_by!(Membership, family_id: child.family_id, user_id: member.id)

      assert {:ok, _} = Families.remove_member(owner, child, membership)

      assert :error = ApiTokens.authenticate(token.secret)
      assert Repo.get(ApiToken, token.id) == nil
    end
  end

  describe "a token's scope" do
    test "only reaches its own family's children" do
      owner = user_scope_fixture()
      mine = child_fixture(owner)
      other = child_fixture(owner)
      scope = owner |> token_fixture(mine.family_id) |> token_scope()

      assert [mine.id] == Enum.map(Families.list_children(scope), & &1.id)
      assert Families.get_child!(scope, mine.id)
      assert_raise Ecto.NoResultsError, fn -> Families.get_child!(scope, other.id) end
      assert Families.member_role(scope, other) == nil
    end

    test "is capped at the token's role, and never owner" do
      owner = user_scope_fixture()
      child = child_fixture(owner)

      writer = owner |> token_fixture(child.family_id, %{role: :caregiver}) |> token_scope()
      reader = owner |> token_fixture(child.family_id, %{role: :viewer}) |> token_scope()

      assert Families.member_role(writer, child) == :caregiver
      assert Families.member_role(reader, child) == :viewer
      assert Families.get_child!(reader, child.id).role == :viewer

      assert_raise Families.NotAuthorizedError, fn ->
        Families.authorize!(writer, child, :owner)
      end

      assert_raise Families.NotAuthorizedError, fn ->
        Families.update_child(writer, child, %{name: "x"})
      end

      assert_raise Families.NotAuthorizedError, fn -> Families.delete_child(writer, child) end

      assert_raise Families.NotAuthorizedError, fn ->
        Families.create_child(writer, valid_child_attributes())
      end
    end

    test "follows the issuer's role if they are demoted" do
      %{owner_scope: owner, child: child, member: member, member_scope: member_scope} =
        shared_child_fixture(:caregiver)

      scope = member_scope |> token_fixture(child.family_id, %{role: :caregiver}) |> token_scope()
      assert Families.member_role(scope, child) == :caregiver

      membership = Repo.get_by!(Membership, family_id: child.family_id, user_id: member.id)
      {:ok, _} = Families.update_member_role(owner, child, membership, :viewer)

      assert Families.member_role(scope, child) == :viewer
    end
  end

  describe "listing and revoking" do
    test "caregivers see their own tokens, owners see everyone's" do
      %{owner_scope: owner, child: child, member_scope: member_scope} = shared_child_fixture()
      mine = token_fixture(owner, child.family_id, %{name: "Mine"})
      theirs = token_fixture(member_scope, child.family_id, %{name: "Theirs"})

      assert [theirs.id] ==
               Enum.map(ApiTokens.list_tokens(member_scope, child.family_id), & &1.id)

      assert Enum.sort([mine.id, theirs.id]) ==
               owner |> ApiTokens.list_tokens(child.family_id) |> Enum.map(& &1.id) |> Enum.sort()
    end

    test "the issuer or an owner can revoke; other members can't" do
      %{owner_scope: owner, child: child, member_scope: member_scope} = shared_child_fixture()
      theirs = token_fixture(member_scope, child.family_id)
      owners = token_fixture(owner, child.family_id)

      assert_raise Families.NotAuthorizedError, fn ->
        ApiTokens.revoke_token(member_scope, owners)
      end

      assert {:ok, _} = ApiTokens.revoke_token(member_scope, theirs)
      assert :error = ApiTokens.authenticate(theirs.secret)

      assert {:ok, _} = ApiTokens.revoke_token(owner, owners)
      assert :error = ApiTokens.authenticate(owners.secret)
    end
  end
end
