defmodule Trygg.Growth.WeightRemindersPushTest do
  # async: false — flips `config :trygg, Trygg.Push` (process-global) and uses
  # the shared recording sender.
  use Trygg.DataCase, async: false

  import Trygg.FamiliesFixtures
  import Trygg.GrowthFixtures

  alias Trygg.Accounts
  alias Trygg.Families
  alias Trygg.Growth.WeightReminders

  setup do
    Trygg.Push.Sender.Test.listen()
    prev = Application.get_env(:trygg, Trygg.Push)
    Application.put_env(:trygg, Trygg.Push, Keyword.put(prev, :enabled, true))
    on_exit(fn -> Application.put_env(:trygg, Trygg.Push, prev) end)
    :ok
  end

  defp drain_emails(acc \\ []) do
    receive do
      {:email, email} -> drain_emails([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # 400-day-old child, weight 150 days stale → both caregivers overdue on the
  # 120-day CDC interval.
  defp overdue_child do
    %{owner_scope: owner, child: child, member: member} = shared_child_fixture(:caregiver)

    {:ok, child} =
      Families.update_child(owner, child, %{birth_date: Date.add(Date.utc_today(), -400)})

    measurement_fixture(owner, child, %{"measured_on" => Date.add(Date.utc_today(), -150)})
    drain_emails()
    %{owner: owner, child: child, member: member}
  end

  test "pushes to every subscribed caregiver alongside the email" do
    %{owner: owner, child: child, member: member} = overdue_child()

    {:ok, _} = Trygg.Push.subscribe(owner.user, subscription("owner-device"))
    {:ok, _} = Trygg.Push.subscribe(member, subscription("member-device"))

    assert WeightReminders.run() == 2

    # Email still goes out to both.
    assert length(drain_emails()) == 2

    messages =
      for _ <- 1..2 do
        assert_received {:web_push, sub, message}
        {sub["endpoint"], Jason.decode!(message)}
      end

    endpoints = messages |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    assert endpoints == [
             "https://push.example.com/member-device",
             "https://push.example.com/owner-device"
           ]

    {_endpoint, payload} = hd(messages)
    assert payload["title"] == "Time to check #{child.name}'s weight"
    assert payload["url"] == "/c/#{child.id}/vitals"

    refute_received {:web_push, _, _}
  end

  test "a caregiver's push follows their own cadence setting" do
    %{owner: owner, member: member} = overdue_child()
    {:ok, _} = Accounts.update_user_settings(member, %{"weight_reminder_days" => 0})

    {:ok, _} = Trygg.Push.subscribe(owner.user, subscription("owner-device"))
    {:ok, _} = Trygg.Push.subscribe(member, subscription("member-device"))

    assert WeightReminders.run() == 1

    assert_received {:web_push, %{"endpoint" => "https://push.example.com/owner-device"}, _}
    refute_received {:web_push, _, _}
  end

  test "no push attempt when the caregiver has no subscription" do
    overdue_child()

    assert WeightReminders.run() == 2
    assert drain_emails() != []
    refute_received {:web_push, _, _}
  end

  defp subscription(slug) do
    %{
      "endpoint" => "https://push.example.com/#{slug}",
      "keys" => %{"p256dh" => "BP#{slug}", "auth" => "auth-#{slug}"}
    }
  end
end
