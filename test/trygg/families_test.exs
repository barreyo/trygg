defmodule Trygg.FamiliesTest do
  use Trygg.DataCase, async: true

  import Swoosh.TestAssertions

  alias Trygg.Families
  alias Trygg.Families.{Child, Membership}

  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  describe "create_child/2" do
    test "creates the child and an owner membership" do
      scope = user_scope_fixture()
      assert {:ok, %Child{} = child} = Families.create_child(scope, valid_child_attributes())
      assert child.role == :owner
      assert Families.member_role(scope, child) == :owner
      assert [child.id] == Enum.map(Families.list_children(scope), & &1.id)
    end

    test "validates name" do
      scope = user_scope_fixture()

      assert {:error, changeset} =
               Families.create_child(scope, %{name: "", timezone: "Etc/UTC"})

      assert %{name: _} = errors_on(changeset)
    end
  end

  describe "get_child!/2" do
    test "returns the child with role for a member" do
      %{member_scope: scope, child: child} = shared_child_fixture()
      got = Families.get_child!(scope, child.id)
      assert got.id == child.id
      assert got.role == :caregiver
    end

    test "raises for a non-member" do
      child = child_fixture()
      stranger = user_scope_fixture()
      assert_raise Ecto.NoResultsError, fn -> Families.get_child!(stranger, child.id) end
    end
  end

  describe "authorize!/3" do
    test "passes when role is high enough, raises otherwise" do
      %{owner_scope: owner, member_scope: member, child: child} = shared_child_fixture(:viewer)

      assert Families.authorize!(owner, child, :owner) == :owner
      assert Families.authorize!(member, child, :viewer) == :viewer

      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        Families.authorize!(member, child, :caregiver)
      end
    end
  end

  describe "update_child/3 and delete_child/2" do
    test "only owners may update" do
      %{owner_scope: owner, member_scope: member, child: child} = shared_child_fixture(:caregiver)

      assert {:ok, updated} = Families.update_child(owner, child, %{name: "Renamed"})
      assert updated.name == "Renamed"

      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        Families.update_child(member, child, %{name: "Nope"})
      end
    end

    test "day and night starts default to 08:00 / 20:00 and must differ" do
      scope = user_scope_fixture()
      assert {:ok, child} = Families.create_child(scope, valid_child_attributes())
      assert child.day_start == ~T[08:00:00]
      assert child.night_start == ~T[20:00:00]

      assert {:ok, updated} =
               Families.update_child(scope, child, %{
                 day_start: ~T[07:30:00],
                 night_start: ~T[19:00:00]
               })

      assert updated.day_start == ~T[07:30:00]
      assert updated.night_start == ~T[19:00:00]

      assert {:error, changeset} =
               Families.update_child(scope, updated, %{night_start: ~T[07:30:00]})

      assert %{night_start: _} = errors_on(changeset)
    end

    test "broadcasts to subscribers" do
      %{owner_scope: owner, child: child} = shared_child_fixture()
      Families.subscribe(child.id)
      {:ok, updated} = Families.update_child(owner, child, %{name: "Live"})
      assert_receive {:child_updated, %Child{name: "Live"} = broadcasted}
      assert broadcasted.id == updated.id
    end
  end

  describe "members" do
    test "list_members requires membership and preloads users" do
      %{owner_scope: owner, child: child, member: member} = shared_child_fixture()
      emails = owner |> Families.list_members(child) |> Enum.map(& &1.user.email)
      assert member.email in emails
      assert length(emails) == 2
    end

    test "cannot remove the last owner" do
      scope = user_scope_fixture()
      child = child_fixture(scope)
      [owner_membership] = Repo.all(Membership)
      assert {:error, :last_owner} = Families.remove_member(scope, child, owner_membership)
    end

    test "owner can remove a caregiver" do
      %{owner_scope: owner, child: child, member: member} = shared_child_fixture()
      membership = Repo.get_by!(Membership, child_id: child.id, user_id: member.id)
      assert {:ok, _} = Families.remove_member(owner, child, membership)
      assert Families.member_role(user_scope_fixture(member), child) == nil
    end
  end

  describe "invites" do
    test "invite_caregiver emails a link and lists the invite" do
      scope = user_scope_fixture()
      child = child_fixture(scope)
      # ignore the magic-link email from creating the fixture user
      assert_received {:email, _}

      assert {:ok, invite} =
               Families.invite_caregiver(scope, child, %{email: "CoParent@Example.com"}, fn t ->
                 "http://host/invites/#{t}"
               end)

      assert invite.email == "coparent@example.com"
      assert invite.token
      assert [listed] = Families.list_invites(scope, child)
      assert listed.id == invite.id
      assert_email_sent(to: [{"", "coparent@example.com"}], subject: ~r/invited to help track/)
    end

    test "rejects inviting an existing member" do
      %{owner_scope: owner, child: child, member: member} = shared_child_fixture()

      assert {:error, :already_member} =
               Families.invite_caregiver(owner, child, %{email: member.email}, & &1)
    end

    test "non-owner cannot invite" do
      %{member_scope: member, child: child} = shared_child_fixture(:caregiver)

      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        Families.invite_caregiver(member, child, %{email: "x@example.com"}, & &1)
      end
    end

    test "accept_invite joins the user when the email matches" do
      owner = user_scope_fixture()
      child = child_fixture(owner)
      invitee = user_fixture()
      invite = invite_fixture(owner, child, email: invitee.email, role: :caregiver)

      assert {:ok, joined} = Families.accept_invite(user_scope_fixture(invitee), invite.token)
      assert joined.id == child.id
      assert joined.role == :caregiver
      assert Repo.get_by(Trygg.Families.Invite, id: invite.id).accepted_at
    end

    test "accept_invite refuses a mismatched email" do
      owner = user_scope_fixture()
      child = child_fixture(owner)
      invite = invite_fixture(owner, child, email: "someone-else@example.com")
      other = user_scope_fixture()

      assert {:error, :email_mismatch} = Families.accept_invite(other, invite.token)
    end

    test "accept_invite treats an expired invite as not found" do
      owner = user_scope_fixture()
      child = child_fixture(owner)
      invitee = user_fixture()
      invite = invite_fixture(owner, child, email: invitee.email)

      Repo.update_all(Trygg.Families.Invite,
        set: [
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day) |> DateTime.truncate(:second)
        ]
      )

      assert {:error, :not_found} =
               Families.accept_invite(user_scope_fixture(invitee), invite.token)
    end
  end
end
