defmodule Trygg.Reports.PredictionE2ETest do
  @moduledoc """
  End-to-end checks against realistic multi-week logs from
  `Trygg.SleepSimulator`. Blocks are inserted a day at a time and a prediction
  is recorded at every wake, exactly as the real app fills a log — then we
  assert the error settles low and unbiased on a steady schedule, recovers
  after a real nap transition, and comes out of `Trygg.Reports.outlook/3` fully
  populated and self-consistent.
  """
  use Trygg.DataCase, async: true

  import Ecto.Query
  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias Trygg.Reports
  alias Trygg.Reports.Day
  alias Trygg.Reports.Insights
  alias Trygg.Reports.Prediction
  alias Trygg.Reports.PredictionLedger
  alias Trygg.SleepSimulator

  defp e2e_child(end_date, age) do
    owner = user_scope_fixture()

    child =
      child_fixture(owner, %{
        timezone: "Etc/UTC",
        day_start: ~T[06:00:00],
        night_start: ~T[19:00:00],
        birth_date: Date.add(end_date, -age)
      })

    %{owner: owner, child: child}
  end

  # Bulk-insert the warm-up history, then replay the rest a block at a time:
  # insert the block, and on every real wake record + reconcile a prediction.
  # `on_wake.(child, now)` fires right after each `track`, before the next
  # (nap) block is inserted — so a probe sees the same log the app did.
  defp replay(child, blocks, replay_from, on_wake \\ fn _c, _now -> :ok end) do
    {warm, live} =
      Enum.split_with(blocks, &(DateTime.compare(&1.started_at, replay_from) == :lt))

    SleepSimulator.insert_blocks(child, warm)

    Enum.each(live, fn block ->
      SleepSimulator.insert_blocks(child, [block])

      if block.wake? do
        now = DateTime.add(block.ended_at, 1, :second)
        PredictionLedger.track(child, now)
        on_wake.(child, now)
      end
    end)
  end

  defp day_from_db(child, date, now) do
    since = DateTime.add(now, -3 * 24 * 3600, :second)

    entries =
      Repo.all(
        from e in Entry,
          where: e.child_id == ^child.id and e.type == :sleep and e.started_at >= ^since
      )

    Day.build(child, date, entries, now)
  end

  defp mae(errors), do: Enum.sum(Enum.map(errors, &abs/1)) / length(errors)

  defp resolved_errors(child_id, kind) do
    Repo.all(
      from p in Prediction,
        where: p.child_id == ^child_id and p.kind == ^kind and not is_nil(p.error_seconds),
        order_by: [asc: p.made_from_ts],
        select: {p.made_from_ts, p.error_seconds}
    )
  end

  defp insert_sleep(child, start, finish) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%Entry{
      child_id: child.id,
      type: :sleep,
      started_at: start,
      ended_at: finish,
      data: %{"location" => "bassinet"},
      inserted_at: now,
      updated_at: now
    })
  end

  describe "steady schedule" do
    test "six weeks of a jittery 3-nap schedule: error settles low and unbiased" do
      end_date = ~D[2026-06-15]
      # Age 129 → 170 across the run: entirely inside the 3-nap model band.
      %{child: child} = e2e_child(end_date, 170)

      %{timeline: tl, blocks: blocks} = SleepSimulator.plan(child, end_date, 42, seed: 7)
      replay(child, blocks, Enum.at(tl, -28).wake_at)

      nap = PredictionLedger.accuracy(child.id, :next_nap, limit: 5000)
      bed = PredictionLedger.accuracy(child.id, :bedtime, limit: 5000)

      assert nap.n >= 60
      assert bed.n >= 20

      assert nap.mae_seconds < 24 * 60
      assert abs(nap.bias_seconds) < 10 * 60
      assert bed.mae_seconds < 32 * 60

      # Settled: the most recent third is no worse than the first third, and the
      # tail is genuinely tight.
      errs = child.id |> resolved_errors(:next_nap) |> Enum.map(&elem(&1, 1))
      third = div(length(errs), 3)
      assert mae(Enum.take(errs, -third)) <= mae(Enum.take(errs, third)) * 1.2
      assert mae(Enum.take(errs, -20)) < 20 * 60

      # Almost everything resolves.
      abandoned =
        Repo.aggregate(
          from(p in Prediction,
            where:
              p.child_id == ^child.id and not is_nil(p.resolved_at) and is_nil(p.error_seconds)
          ),
          :count
        )

      assert abandoned <= 4
    end

    test "history beats the age prior for a baby whose windows run long" do
      end_date = ~D[2026-06-15]
      %{child: child} = e2e_child(end_date, 170)

      # This baby's wake windows run 40% longer than the age model.
      stretched = fn age ->
        m = SleepSimulator.model(age)
        %{m | ww: Enum.map(m.ww, &round(&1 * 1.4))}
      end

      %{timeline: tl, blocks: blocks} =
        SleepSimulator.plan(child, end_date, 35, seed: 11, jitter: :low, model: stretched)

      probe_days =
        tl
        |> Enum.take(-8)
        |> Map.new(fn d -> {DateTime.to_unix(d.wake_at), hd(d.naps) |> elem(0)} end)

      {:ok, agent} = Agent.start_link(fn -> %{history: [], prior: []} end)

      replay(child, blocks, Enum.at(tl, -20).wake_at, fn c, now ->
        wake_unix = DateTime.to_unix(now) - 1

        if actual = probe_days[wake_unix] do
          reload = Repo.get!(Child, c.id)
          today = day_from_db(reload, DateTime.to_date(now), now)

          learned = PredictionLedger.prediction(reload, now).next_nap
          bare = Insights.summarize(reload, [today], today, now).prediction.next_nap

          assert bare.source == :age_prior

          Agent.update(agent, fn acc ->
            %{
              history: [abs(DateTime.diff(learned.at, actual, :second)) | acc.history],
              prior: [abs(DateTime.diff(bare.at, actual, :second)) | acc.prior]
            }
          end)
        end
      end)

      %{history: history, prior: prior} = Agent.get(agent, & &1)

      assert length(history) >= 6
      # Same moments, same real outcome: the learned windows beat the prior.
      assert mae(history) < mae(prior) * 0.7
    end
  end

  describe "nap transition" do
    test "a real 3-to-2 nap transition is flagged and the model re-locks" do
      end_date = ~D[2026-07-20]
      # Age 150 → 205: crosses the model's 3→2 boundary at day ≈ 30.
      %{child: child} = e2e_child(end_date, 205)

      %{timeline: tl, blocks: blocks} = SleepSimulator.plan(child, end_date, 56, seed: 5)
      switch = Enum.find(tl, &(&1.age_days == 180))
      assert switch, "run should span the 3→2 boundary"

      replay(child, blocks, Enum.at(tl, -42).wake_at)

      # In the fortnight after the switch the model calls it a transition at
      # least once (checked mid-afternoon, when the schedule is unsettled).
      flagged? =
        Enum.any?(2..12, fn offset ->
          at = DateTime.new!(Date.add(switch.date, offset), ~T[14:30:00], "Etc/UTC")
          PredictionLedger.prediction(child.id, at).transition? == true
        end)

      assert flagged?

      by_week =
        child.id
        |> resolved_errors(:next_nap)
        |> Enum.group_by(fn {ts, _e} ->
          div(Date.diff(DateTime.to_date(ts), switch.date), 7)
        end)
        |> Map.new(fn {wk, rows} -> {wk, mae(Enum.map(rows, &elem(&1, 1)))} end)

      switch_week = by_week[0]
      settled_week = by_week[2] || by_week[3]
      assert switch_week && settled_week

      # The switch disrupts accuracy, then it recovers.
      assert switch_week > settled_week
      assert settled_week < 32 * 60

      # By the end the live read is a confident, non-transition 2-nap schedule.
      final =
        PredictionLedger.prediction(child.id, DateTime.new!(end_date, ~T[13:00:00], "Etc/UTC"))

      assert final.transition? == false
    end
  end

  describe "Reports.outlook/3 end to end" do
    test "returns a fully populated, self-consistent prediction" do
      today = Date.utc_today()
      # Age ≥ 185 for the whole month → wholly inside the 2-nap band.
      %{child: child, owner: owner} = e2e_child(today, 215)

      SleepSimulator.generate(child, Date.add(today, -1), 30, seed: 3)

      insert_sleep(
        child,
        DateTime.new!(Date.add(today, -1), ~T[19:15:00], "Etc/UTC"),
        DateTime.new!(today, ~T[06:55:00], "Etc/UTC")
      )

      nap1_end = DateTime.new!(today, ~T[10:20:00], "Etc/UTC")
      insert_sleep(child, DateTime.new!(today, ~T[09:05:00], "Etc/UTC"), nap1_end)

      now = DateTime.new!(today, ~T[12:30:00], "Etc/UTC")
      %{prediction: p} = Reports.outlook(owner, child, now)

      assert p.state == :awake
      assert p.transition? == false

      assert p.next_nap.ordinal == 2
      assert p.next_nap.source in [:history, :blended]
      assert p.next_nap.in_seconds > 0
      assert p.next_nap.range.label =~ ~r/^\d\d:\d\d–\d\d:\d\d$/
      assert DateTime.compare(p.next_nap.at, now) == :gt

      assert p.wake_pressure.state in [:fresh, :approaching, :past]
      assert p.wake_pressure.awake_seconds == DateTime.diff(now, nap1_end, :second)

      assert p.bedtime
      assert is_integer(p.bedtime.shifted_by_seconds)
      assert DateTime.compare(p.bedtime.at, p.next_nap.at) == :gt

      # The rest-of-day schedule runs strictly forward and ends at bedtime.
      assert p.schedule != []

      assert p.schedule
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> DateTime.compare(b.start, a.end) != :lt end)

      assert List.last(p.schedule).kind == :bed

      # Next nap lands near where the age model puts the second wake window.
      model = SleepSimulator.model(215)
      expected = DateTime.add(nap1_end, Enum.at(model.ww, 1) * 60, :second)
      assert abs(DateTime.diff(p.next_nap.at, expected, :second)) < 60 * 60
    end
  end
end
