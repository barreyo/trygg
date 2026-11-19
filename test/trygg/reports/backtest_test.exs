defmodule Trygg.Reports.BacktestTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias Trygg.Reports.Backtest
  alias Trygg.Reports.Insights

  defp child do
    %Child{timezone: "Etc/UTC", day_start: ~T[08:00:00], night_start: ~T[20:00:00]}
  end

  defp sleep(start, finish) do
    %Entry{
      id: System.unique_integer([:positive]),
      type: :sleep,
      started_at: start,
      ended_at: finish,
      data: %{}
    }
  end

  defp dt(date, time), do: DateTime.new!(date, time, "Etc/UTC")

  # A steady rhythm: down at 20:30, a feed after 6.5h, up at 07:00, naps at
  # 09:30 and 13:00.
  defp steady_entries(from, to) do
    for date <- Date.range(from, to), reduce: [] do
      acc ->
        next = Date.add(date, 1)

        acc ++
          [
            sleep(dt(date, ~T[09:30:00]), dt(date, ~T[10:30:00])),
            sleep(dt(date, ~T[13:00:00]), dt(date, ~T[14:00:00])),
            sleep(dt(date, ~T[20:30:00]), dt(next, ~T[03:00:00])),
            sleep(dt(next, ~T[03:30:00]), dt(next, ~T[07:00:00]))
          ]
    end
  end

  setup do
    entries = steady_entries(~D[2026-02-28], ~D[2026-03-25])
    %{entries: entries}
  end

  test "scores every kind on a steady rhythm, with very small errors", %{entries: entries} do
    %{points: points, kinds: kinds} = Backtest.run(child(), entries, to: ~D[2026-03-24], days: 7)

    assert points > 0

    for kind <- Backtest.kinds() do
      assert %{n: n, mae_seconds: mae} = kinds[kind]
      assert n >= 5, "#{kind} scored only #{n} predictions"
      assert mae <= 5 * 60, "#{kind} was off by #{mae}s on a perfectly steady rhythm"
    end

    assert kinds.next_feed.within_15_min == 1.0
    assert kinds.bedtime.in_range in [nil, 1.0]
  end

  test "only uses what had been logged by then", %{entries: entries} do
    # A nap logged tomorrow cannot help predict today's. If it leaked, moving
    # the whole later history around would change the earlier scores.
    early = Backtest.run(child(), entries, to: ~D[2026-03-20], days: 5)

    shuffled =
      entries ++
        [sleep(dt(~D[2026-03-22], ~T[03:00:00]), dt(~D[2026-03-22], ~T[03:20:00]))]

    again = Backtest.run(child(), shuffled, to: ~D[2026-03-20], days: 5)
    assert early.kinds.next_nap == again.kinds.next_nap
    assert early.kinds.bedtime == again.kinds.bedtime
  end

  test "compare runs each variant", %{entries: entries} do
    results =
      Backtest.compare(
        child(),
        entries,
        [current: [], legacy: [features: Insights.legacy_features()]],
        to: ~D[2026-03-24],
        days: 5
      )

    assert [{:current, current}, {:legacy, legacy}] = results
    assert current.points == legacy.points
    assert current.kinds.next_feed.n > 0
    # Same points scored for both; the variants differ in how they predict.
    for kind <- Backtest.kinds() do
      assert current.kinds[kind].n == legacy.kinds[kind].n
    end
  end

  test "an empty log scores nothing" do
    assert %{points: 0, kinds: kinds} = Backtest.run(child(), [])
    assert Enum.all?(kinds, fn {_kind, s} -> s.n == 0 end)
  end
end
