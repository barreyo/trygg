defmodule Trygg.Reports.FallingAsleepTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias Trygg.Reports.FallingAsleep

  @today ~D[2026-10-10]
  @child %Child{timezone: "Etc/UTC"}

  defp sleep(days_ago, data) do
    date = Date.add(@today, -days_ago)
    at = DateTime.new!(date, ~T[10:00:00], "Etc/UTC")
    %Entry{type: :sleep, started_at: at, ended_at: DateTime.add(at, 3600), data: data}
  end

  defp summarize(entries), do: FallingAsleep.summarize(@child, entries, @today)

  test "no tracked sleeps gives empty weeks" do
    result = summarize([sleep(0, %{}), sleep(1, %{"cue" => "ready"})])

    assert result.tracked == 0
    assert length(result.weeks) == 6
    assert Enum.all?(result.weeks, &(&1.n == 0 and is_nil(&1.mean_level)))
    assert result.this_week.mean_level == nil
    assert result.trend == nil
    assert result.latest == nil
  end

  test "averages the level for the week, with the settle time and independent share" do
    result =
      summarize([
        sleep(0, %{"assist" => 7, "settle_minutes" => 10}),
        sleep(1, %{"assist" => 9, "settle_minutes" => 5}),
        sleep(2, %{"assist" => 8, "settle_minutes" => 20}),
        sleep(3, %{"assist" => 4})
      ])

    week = result.this_week
    assert week.n == 4
    assert week.mean_level == 7.0
    assert week.median_settle == 10
    assert week.independent_share == 0.5
    assert result.tracked == 4
    assert result.latest == 7
  end

  test "weeks end today and run back, oldest first" do
    result = summarize([sleep(0, %{"assist" => 5})])
    assert List.last(result.weeks).to == @today
    assert List.last(result.weeks).from == Date.add(@today, -6)
    assert hd(result.weeks).to == Date.add(@today, -35)
  end

  test "trend compares this week with the latest earlier week that has data" do
    result =
      summarize([
        sleep(0, %{"assist" => 8}),
        sleep(1, %{"assist" => 6}),
        # Two weeks back; last week has nothing.
        sleep(15, %{"assist" => 4}),
        sleep(16, %{"assist" => 4})
      ])

    assert result.this_week.mean_level == 7.0
    assert result.previous.mean_level == 4.0
    assert result.trend == 3.0
  end

  test "sleeps older than six weeks and out-of-range levels are ignored" do
    result = summarize([sleep(50, %{"assist" => 3}), sleep(0, %{"assist" => 6})])
    assert result.tracked == 1
  end
end
