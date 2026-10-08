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

  describe "update_tracked_types/3" do
    test "caregivers may change the layout, but only that" do
      %{member_scope: member, child: child} = shared_child_fixture(:caregiver)

      assert {:ok, updated} = Families.update_tracked_types(member, child, [:feeding])
      assert updated.tracked_types == [:feeding]
      assert updated.name == child.name
      assert updated.role == :caregiver
    end

    test "viewers may not" do
      %{member_scope: member, child: child} = shared_child_fixture(:viewer)

      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        Families.update_tracked_types(member, child, [:feeding])
      end
    end

    test "something must stay tracked" do
      scope = user_scope_fixture()
      child = child_fixture(scope)

      assert {:error, %Ecto.Changeset{}} = Families.update_tracked_types(scope, child, [])
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

  describe "expecting children" do
    setup do
      scope = user_scope_fixture()

      {:ok, child} =
        Families.create_child(
          scope,
          valid_child_attributes(%{
            birth_date: nil,
            expected_birth_date: Date.add(Date.utc_today(), 30)
          })
        )

      %{scope: scope, child: child}
    end

    test "create_child with only a due date is 'expecting'", %{child: child} do
      assert Child.expecting?(child)
      assert child.birth_date == nil
    end

    test "confirming the birth date clears the practice log and broadcasts :child_born",
         %{scope: scope, child: child} do
      entry = Trygg.LogFixtures.entry_fixture(scope, child, %{type: :diaper})
      _measurement = Trygg.GrowthFixtures.measurement_fixture(scope, child)

      Families.subscribe(child.id)

      assert {:ok, born} =
               Families.update_child(scope, child, %{birth_date: Date.utc_today()})

      refute Child.expecting?(born)
      assert born.expected_birth_date == nil
      # Due in 30 days → born at 35+5 weeks.
      assert born.gestational_age_days == 250

      assert_receive {:child_born, %Child{} = broadcasted}
      assert broadcasted.id == child.id
      refute_receive {:child_updated, _}

      assert Trygg.Log.list_entries(scope, born) == []
      assert Trygg.Repo.get(Trygg.Log.Entry, entry.id) == nil
      assert Trygg.Growth.list_measurements(scope, born) == []
    end

    test "a gestational age given at birth wins over the due date",
         %{scope: scope, child: child} do
      assert {:ok, born} =
               Families.update_child(scope, child, %{
                 birth_date: Date.utc_today(),
                 gestation_weeks: 33,
                 gestation_extra_days: 1
               })

      assert born.gestational_age_days == 232
    end

    test "editing other fields while still expecting keeps the practice log", %{
      scope: scope,
      child: child
    } do
      entry = Trygg.LogFixtures.entry_fixture(scope, child, %{type: :diaper})
      Families.subscribe(child.id)

      assert {:ok, updated} = Families.update_child(scope, child, %{name: "Peanut"})
      assert Child.expecting?(updated)

      assert_receive {:child_updated, %Child{name: "Peanut"}}
      refute_receive {:child_born, _}

      assert Trygg.Repo.get(Trygg.Log.Entry, entry.id) != nil
    end

    test "setting a due date on a born child re-opens practice mode without wiping data" do
      scope = user_scope_fixture()

      child =
        child_fixture(scope, %{
          birth_date: Date.add(Date.utc_today(), -10),
          birth_time: ~T[12:00:00],
          gestation_weeks: 34
        })

      entry = Trygg.LogFixtures.entry_fixture(scope, child, %{type: :diaper})

      Families.subscribe(child.id)

      assert {:ok, expecting} =
               Families.update_child(scope, child, %{
                 expected_birth_date: Date.add(Date.utc_today(), 20)
               })

      assert Child.expecting?(expecting)
      assert expecting.birth_date == nil
      assert expecting.birth_time == nil
      assert expecting.gestational_age_days == nil

      assert_receive {:child_updated, %Child{} = broadcasted}
      assert broadcasted.id == child.id
      refute_receive {:child_born, _}

      # Existing entries stay put — they just become practice data now.
      assert Trygg.Repo.get(Trygg.Log.Entry, entry.id) != nil
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
      membership = Repo.get_by!(Membership, family_id: child.family_id, user_id: member.id)
      assert {:ok, _} = Families.remove_member(owner, child, membership)
      assert Families.member_role(user_scope_fixture(member), child) == nil
    end
  end

  describe "families" do
    test "a new child starts a family of its own" do
      scope = user_scope_fixture()
      first = child_fixture(scope)
      second = child_fixture(scope)

      assert first.family_id != second.family_id
    end

    test "a child can join a family the user owns, and its caregivers see it" do
      %{owner_scope: owner, child: first, member: member, member_scope: member_scope} =
        shared_child_fixture(:viewer)

      second = child_fixture(owner, %{name: "Second"}, family_id: first.family_id)

      assert second.family_id == first.family_id
      assert second.id in Enum.map(Families.list_children(member_scope), & &1.id)
      assert Families.member_role(member_scope, second) == :viewer
      assert Families.get_child!(member_scope, second.id).role == :viewer
      assert member.id
    end

    test "only an owner of the family can add a child to it" do
      %{child: child, member_scope: member_scope} = shared_child_fixture(:caregiver)

      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        Families.create_child(member_scope, valid_child_attributes(), family_id: child.family_id)
      end

      stranger = user_scope_fixture()

      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        Families.create_child(stranger, valid_child_attributes(), family_id: child.family_id)
      end
    end

    test "list_owned_families only returns families the user owns" do
      %{owner_scope: owner, child: child, member_scope: member_scope} = shared_child_fixture()

      assert [%{id: id, children: [%{id: child_id}]}] = Families.list_owned_families(owner)
      assert id == child.family_id
      assert child_id == child.id
      assert Families.list_owned_families(member_scope) == []
    end

    test "deleting one of two children keeps the family; deleting the last removes it" do
      %{owner_scope: owner, child: first, member_scope: member_scope} = shared_child_fixture()
      second = child_fixture(owner, %{}, family_id: first.family_id)

      assert {:ok, _} = Families.delete_child(owner, first)
      assert Families.member_role(member_scope, second) == :caregiver
      assert Repo.get(Trygg.Families.Family, second.family_id)

      assert {:ok, _} = Families.delete_child(owner, second)
      refute Repo.get(Trygg.Families.Family, second.family_id)
      assert Repo.all(Membership) == []
    end

    test "an accepted invite gives access to every child in the family" do
      owner = user_scope_fixture()
      first = child_fixture(owner)
      second = child_fixture(owner, %{}, family_id: first.family_id)
      invitee = user_fixture()
      invite = invite_fixture(owner, first, %{email: invitee.email})
      invitee_scope = user_scope_fixture(invitee)

      assert {:ok, _child} = Families.accept_invite(invitee_scope, invite.token)

      assert Enum.sort([first.id, second.id]) ==
               invitee_scope |> Families.list_children() |> Enum.map(& &1.id) |> Enum.sort()
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
