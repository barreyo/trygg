defmodule Trygg.Growth.WeightRemindersTest do
  use Trygg.DataCase, async: true

  import Trygg.FamiliesFixtures
  import Trygg.GrowthFixtures

  alias Trygg.Accounts
  alias Trygg.Families
  alias Trygg.Growth.WeightReminders

  # Pulls every email Swoosh has delivered to this process off the mailbox.
  defp drain_emails(acc \\ []) do
    receive do
      {:email, email} -> drain_emails([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A shared child aged so the 120-day (12–24mo) CDC interval applies, with an
  # optional weight `days_ago` old. Clears fixture signup emails afterwards.
  defp overdue_child(days_ago) do
    %{owner_scope: owner, child: child, member: member} = shared_child_fixture(:caregiver)

    {:ok, child} =
      Families.update_child(owner, child, %{birth_date: Date.add(Date.utc_today(), -400)})

    if days_ago do
      measurement_fixture(owner, child, %{"measured_on" => Date.add(Date.utc_today(), -days_ago)})
    end

    drain_emails()
    %{owner: owner, child: child, member: member}
  end

  test "emails every owner and caregiver when a weight check is overdue" do
    %{owner: owner, child: child, member: member} = overdue_child(150)

    assert WeightReminders.run() == 2

    emails = drain_emails()
    assert Enum.all?(emails, &(&1.subject == "Time to check #{child.name}'s weight"))

    recipients = emails |> Enum.flat_map(& &1.to) |> Enum.map(fn {_name, addr} -> addr end)
    assert owner.user.email in recipients
    assert member.email in recipients
  end

  test "reminds even when a weight was never logged for an older child" do
    %{child: child} = overdue_child(nil)

    assert WeightReminders.run() == 2

    assert [email | _] = drain_emails()
    assert email.subject == "Time to check #{child.name}'s weight"
    assert email.text_body =~ "No weight has been logged"
  end

  test "does not email again before that caregiver's interval has passed" do
    overdue_child(150)

    assert WeightReminders.run() == 2
    assert drain_emails() != []

    assert WeightReminders.run() == 0
    assert drain_emails() == []
  end

  test "no email when a recent weight is on file" do
    overdue_child(5)

    assert WeightReminders.run() == 0
    assert drain_emails() == []
  end

  test "honours a caregiver's shorter custom cadence" do
    %{owner: owner, member: member} = overdue_child(20)

    # 20 days stale: under the 120-day CDC interval, so nobody is due yet.
    assert WeightReminders.run() == 0
    drain_emails()

    # The caregiver asks for a 7-day cadence; now only they are due.
    {:ok, _} = Accounts.update_user_settings(member, %{"weight_reminder_days" => 7})

    assert WeightReminders.run() == 1

    recipients = drain_emails() |> Enum.flat_map(& &1.to) |> Enum.map(fn {_n, a} -> a end)
    assert recipients == [member.email]
    refute owner.user.email in recipients
  end

  test "a caregiver who turned reminders off is skipped" do
    %{owner: owner, member: member} = overdue_child(150)
    {:ok, _} = Accounts.update_user_settings(member, %{"weight_reminder_days" => 0})

    assert WeightReminders.run() == 1

    recipients = drain_emails() |> Enum.flat_map(& &1.to) |> Enum.map(fn {_n, a} -> a end)
    assert recipients == [owner.user.email]
  end
end
