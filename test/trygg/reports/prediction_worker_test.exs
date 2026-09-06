defmodule Trygg.Reports.PredictionWorkerTest do
  use Trygg.DataCase, async: false
  use Oban.Testing, repo: Trygg.Repo

  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures
  import Trygg.LogFixtures

  alias Trygg.Log
  alias Trygg.Reports.Prediction
  alias Trygg.Reports.PredictionWorker

  defp child_with_history do
    owner = user_scope_fixture()
    child = child_fixture(owner, %{timezone: midday_timezone()})
    sleep_days(owner, child, 7)
    %{owner: owner, child: child}
  end

  test "perform/1 with a child_id records that child's open predictions" do
    %{child: child} = child_with_history()

    assert :ok = perform_job(PredictionWorker, %{child_id: child.id})

    assert Repo.exists?(from p in Prediction, where: p.child_id == ^child.id)
  end

  test "perform/1 with no args sweeps recently-active children" do
    %{child: child} = child_with_history()

    assert :ok = perform_job(PredictionWorker, %{})

    assert Repo.exists?(from p in Prediction, where: p.child_id == ^child.id)
  end

  test "a sleep write enqueues the worker when tracking is enabled" do
    %{owner: owner, child: child} = child_with_history()

    prev = Application.get_env(:trygg, Trygg.Reports)
    Application.put_env(:trygg, Trygg.Reports, track_predictions: true)
    on_exit(fn -> Application.put_env(:trygg, Trygg.Reports, prev) end)

    {:ok, _entry} =
      Log.create_entry(owner, child, :sleep, %{
        "started_at" => DateTime.utc_now() |> DateTime.truncate(:second),
        "data" => %{"location" => "bassinet"}
      })

    assert_enqueued(worker: PredictionWorker, args: %{child_id: child.id})
  end

  test "a sleep write does not enqueue when tracking is disabled (test default)" do
    %{owner: owner, child: child} = child_with_history()

    {:ok, _entry} =
      Log.create_entry(owner, child, :sleep, %{
        "started_at" => DateTime.utc_now() |> DateTime.truncate(:second),
        "data" => %{"location" => "bassinet"}
      })

    refute_enqueued(worker: PredictionWorker)
  end
end
