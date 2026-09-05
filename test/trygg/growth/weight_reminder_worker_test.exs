defmodule Trygg.Growth.WeightReminderWorkerTest do
  use Trygg.DataCase, async: true
  use Oban.Testing, repo: Trygg.Repo

  import Trygg.FamiliesFixtures
  import Trygg.GrowthFixtures

  alias Trygg.Families
  alias Trygg.Growth.WeightReminderWorker

  test "perform runs the scan and emails overdue caregivers" do
    %{owner_scope: owner, child: child} = shared_child_fixture(:caregiver)

    {:ok, child} =
      Families.update_child(owner, child, %{birth_date: Date.add(Date.utc_today(), -400)})

    measurement_fixture(owner, child, %{"measured_on" => Date.add(Date.utc_today(), -200)})

    assert :ok = perform_job(WeightReminderWorker, %{})

    assert_receive {:email, %{subject: "Time to check " <> _}}
  end
end
