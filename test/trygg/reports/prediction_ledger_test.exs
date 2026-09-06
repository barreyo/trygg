defmodule Trygg.Reports.PredictionLedgerTest do
  use Trygg.DataCase, async: true

  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures
  import Trygg.LogFixtures

  alias Trygg.Families.Child
  alias Trygg.Log
  alias Trygg.Reports.Prediction
  alias Trygg.Reports.PredictionLedger

  # A child in a zone where "now" is early afternoon, with a week of regular
  # sleep (07:00 wake, naps 10–11 and 14–15, 20:00 bed) and this morning's
  # wake already logged — so a prediction is due but no nap has happened yet.
  defp awake_child do
    owner = user_scope_fixture()

    child =
      child_fixture(owner, %{
        timezone: midday_timezone(),
        birth_date: Date.add(Date.utc_today(), -120)
      })

    sleep_days(owner, child, 7)
    %{owner: owner, child: child}
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp rows(child, kind) do
    Repo.all(
      from p in Prediction,
        where: p.child_id == ^child.id and p.kind == ^kind,
        order_by: [asc: p.id]
    )
  end

  describe "track/2 recording" do
    test "opens a next_nap and a bedtime row keyed off this morning's wake" do
      %{child: child} = awake_child()

      assert :ok = PredictionLedger.track(child, now())

      assert [%Prediction{} = nap] = rows(child, :next_nap)
      assert nap.resolved_at == nil
      assert nap.ordinal == 1
      assert nap.source in [:history, :blended, :age_prior]

      wake = Child.at_local(child, Child.local_today(child), ~T[07:00:00])
      assert DateTime.compare(nap.made_from_ts, wake) == :eq
      assert DateTime.compare(nap.target_ts, nap.made_from_ts) == :gt

      assert [%Prediction{resolved_at: nil}] = rows(child, :bedtime)
    end

    test "a re-run refines the still-open row instead of adding another" do
      %{child: child} = awake_child()

      PredictionLedger.track(child, now())
      [first] = rows(child, :next_nap)

      PredictionLedger.track(child, DateTime.add(now(), 120, :second))
      assert [second] = rows(child, :next_nap)
      assert second.id == first.id
    end

    test "records nothing while the child is asleep" do
      %{owner: owner, child: child} = awake_child()

      {:ok, _} =
        Log.start_timer(owner, child, :sleep, %{
          "started_at" => DateTime.add(now(), -1800, :second)
        })

      PredictionLedger.track(child, now())

      assert rows(child, :next_nap) == []
      assert rows(child, :bedtime) == []
    end
  end

  describe "track/2 reconciliation" do
    test "closes a matured next_nap row with a signed error" do
      %{owner: owner, child: child} = awake_child()

      PredictionLedger.track(child, now())
      [nap] = rows(child, :next_nap)

      # The child actually falls asleep 18 minutes after the predicted target.
      actual_start = DateTime.add(nap.target_ts, 18 * 60, :second)

      entry_fixture(owner, child, %{
        :type => :sleep,
        "started_at" => actual_start,
        "ended_at" => DateTime.add(actual_start, 3600, :second)
      })

      PredictionLedger.track(child, DateTime.add(actual_start, 4000, :second))

      nap = Repo.get!(Prediction, nap.id)
      assert nap.resolved_at != nil
      assert DateTime.compare(nap.actual_ts, actual_start) == :eq
      assert nap.error_seconds == 18 * 60
    end

    test "does not reopen or re-resolve a row that already resolved" do
      %{owner: owner, child: child} = awake_child()

      PredictionLedger.track(child, now())
      [nap] = rows(child, :next_nap)
      actual_start = DateTime.add(nap.target_ts, 300, :second)

      entry_fixture(owner, child, %{
        :type => :sleep,
        "started_at" => actual_start,
        "ended_at" => DateTime.add(actual_start, 3600, :second)
      })

      PredictionLedger.track(child, DateTime.add(actual_start, 4000, :second))
      resolved = Repo.get!(Prediction, nap.id)

      PredictionLedger.track(child, DateTime.add(actual_start, 8000, :second))
      again = Repo.get!(Prediction, nap.id)

      assert again.resolved_at == resolved.resolved_at
      assert again.error_seconds == resolved.error_seconds
    end

    test "abandons a next_nap row when nothing sleeps within the horizon" do
      %{child: child} = awake_child()

      stale =
        %Prediction{child_id: child.id, kind: :next_nap}
        |> Prediction.changeset(%{
          made_at: DateTime.add(now(), -9 * 3600, :second),
          made_from_ts: DateTime.add(now(), -9 * 3600, :second),
          ordinal: 1,
          source: :age_prior,
          target_ts: DateTime.add(now(), -7 * 3600, :second)
        })
        |> Repo.insert!()

      PredictionLedger.track(child, now())

      reloaded = Repo.get!(Prediction, stale.id)
      assert reloaded.resolved_at != nil
      assert reloaded.error_seconds == nil
      assert reloaded.actual_ts == nil
    end
  end

  describe "accuracy/3" do
    test "returns recency-weighted MAE and signed bias" do
      %{child: child} = awake_child()

      [10, -10, 30, -30, 20]
      |> Enum.with_index()
      |> Enum.each(fn {mins, i} ->
        %Prediction{child_id: child.id, kind: :next_nap}
        |> Prediction.changeset(%{
          made_at: now(),
          made_from_ts: DateTime.add(now(), -(i + 1) * 3600, :second),
          ordinal: 1,
          source: :history,
          target_ts: now(),
          actual_ts: DateTime.add(now(), mins * 60, :second),
          error_seconds: mins * 60,
          resolved_at: DateTime.add(now(), -i * 60, :second)
        })
        |> Repo.insert!()
      end)

      acc = PredictionLedger.accuracy(child.id, :next_nap)
      assert acc.n == 5
      assert acc.mae_seconds > 0
      # Newest resolved rows (errors 10, -10) dominate → bias near zero.
      assert abs(acc.bias_seconds) < 15 * 60
    end

    test "nil when nothing has resolved" do
      %{child: child} = awake_child()
      assert PredictionLedger.accuracy(child.id, :bedtime) == nil
    end
  end

  describe "prediction_opts/1" do
    test "surfaces a bias and a halved half-life once errors lean one way" do
      %{child: child} = awake_child()

      for i <- 1..5 do
        %Prediction{child_id: child.id, kind: :next_nap}
        |> Prediction.changeset(%{
          made_at: now(),
          made_from_ts: DateTime.add(now(), -i * 3600, :second),
          ordinal: 1,
          source: :history,
          target_ts: now(),
          actual_ts: DateTime.add(now(), 40 * 60, :second),
          error_seconds: 40 * 60,
          resolved_at: DateTime.add(now(), -i * 60, :second)
        })
        |> Repo.insert!()
      end

      opts = PredictionLedger.prediction_opts(child.id)

      assert opts[:half_life_days] ==
               max(div(Trygg.Reports.Insights.recency_half_life_days(), 2), 1)

      assert opts[:bias][:next_nap] == 40 * 60
      assert opts[:bias][:bedtime] == 0
    end

    test "no bias or override with a clean history" do
      %{child: child} = awake_child()
      opts = PredictionLedger.prediction_opts(child.id)

      assert opts[:half_life_days] == nil
      assert opts[:bias] == %{next_nap: 0, bedtime: 0}
    end
  end

  describe "sweep/1" do
    test "tracks only children with a sleep logged in the last two days" do
      %{child: active} = awake_child()

      owner = user_scope_fixture()
      stale = child_fixture(owner, %{timezone: midday_timezone()})
      old = DateTime.add(now(), -3 * 24 * 3600, :second)

      entry_fixture(owner, stale, %{
        :type => :sleep,
        "started_at" => old,
        "ended_at" => DateTime.add(old, 3600, :second)
      })

      assert PredictionLedger.sweep(now()) == 1
      assert length(rows(active, :next_nap)) == 1
      assert rows(stale, :next_nap) == []
    end
  end
end
