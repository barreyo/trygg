defmodule Trygg.Growth.ReminderSchedulerTest do
  use Trygg.DataCase, async: true

  import Trygg.FamiliesFixtures
  import Trygg.GrowthFixtures

  alias Trygg.Families
  alias Trygg.Growth.ReminderScheduler

  # Pulls every email Swoosh has delivered to this process off the mailbox.
  defp drain_emails(acc \\ []) do
    receive do
      {:email, email} -> drain_emails([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A shared child aged so the 90-day (4–12mo) check interval applies, with an
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

    assert ReminderScheduler.run() == 1

    emails = drain_emails()
    assert length(emails) == 2
    assert Enum.all?(emails, &(&1.subject == "Time to check #{child.name}'s weight"))

    recipients = emails |> Enum.flat_map(& &1.to) |> Enum.map(fn {_name, addr} -> addr end)
    assert owner.user.email in recipients
    assert member.email in recipients
  end

  test "reminds even when a weight was never logged for an older child" do
    %{child: child} = overdue_child(nil)

    assert ReminderScheduler.run() == 1

    assert [email | _] = drain_emails()
    assert email.subject == "Time to check #{child.name}'s weight"
    assert email.text_body =~ "No weight has been logged"
  end

  test "does not email again before the interval has passed" do
    overdue_child(150)

    assert ReminderScheduler.run() == 1
    assert drain_emails() != []

    assert ReminderScheduler.run() == 0
    assert drain_emails() == []
  end

  test "no email when a recent weight is on file" do
    overdue_child(5)

    assert ReminderScheduler.run() == 0
    assert drain_emails() == []
  end
end
