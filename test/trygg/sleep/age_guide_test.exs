defmodule Trygg.Sleep.AgeGuideTest do
  use ExUnit.Case, async: true

  alias Trygg.Sleep.AgeGuide

  describe "band/1" do
    test "picks the band by corrected age" do
      assert AgeGuide.band(0).id == :birth_6w
      assert AgeGuide.band(28).id == :birth_6w
      assert AgeGuide.band(42).id == :six_weeks_3m
      assert AgeGuide.band(100).id == :three_6m
      assert AgeGuide.band(200).id == :six_9m
      assert AgeGuide.band(300).id == :nine_12m
      assert AgeGuide.band(400).id == :twelve_18m
      assert AgeGuide.band(1000).id == :eighteen_36m
    end

    test "is nil without an age" do
      assert AgeGuide.band(nil) == nil
      assert AgeGuide.band(-3) == nil
    end

    test "the bands start where the previous one ends, youngest first" do
      froms = Enum.map(AgeGuide.bands(), & &1.from_days)
      assert froms == Enum.sort(froms)
      assert hd(froms) == 0
    end
  end

  describe "wake_time/1" do
    test "gives the month's row" do
      assert AgeGuide.wake_time(10).wake == {30, 60}
      assert AgeGuide.wake_time(130).label == "5 months"
      assert AgeGuide.wake_time(300).label == "9 to 12 months"
    end
  end

  describe "compare/2" do
    test "says whether each number sits inside, below or above the range" do
      band = AgeGuide.band(100)

      lines =
        AgeGuide.compare(band, %{
          naps: 4,
          nap_minutes: 90,
          night_hours: 8.0,
          total_hours: 13.0,
          bedtime: 20 * 60
        })

      verdicts = Map.new(lines, &{&1.metric, &1.verdict})
      assert verdicts.naps == :above
      assert verdicts.nap_minutes == :within
      assert verdicts.night_hours == :below
      assert verdicts.total_hours == :within
      assert verdicts.bedtime == :within
    end

    test "leaves out what isn't known" do
      assert [%{metric: :naps}] = AgeGuide.compare(AgeGuide.band(100), %{naps: 3, bedtime: nil})
      assert AgeGuide.compare(nil, %{naps: 3}) == []
    end

    test "gives a little slack at the edges" do
      assert [%{verdict: :within}] = AgeGuide.compare(AgeGuide.band(100), %{naps: 3.4})
    end
  end

  describe "stats_from/1" do
    test "is empty until there's enough history" do
      assert AgeGuide.stats_from(%{ready?: false}) == %{}
    end

    test "turns an insights summary into the numbers to compare" do
      insights = %{
        ready?: true,
        naps: %{
          count: %{median: 3.0},
          by_ordinal: [%{median: 3600.0}, %{median: 5400.0}, %{median: nil}]
        },
        totals: %{night: %{median: 10 * 3600.0}, total: %{median: 13 * 3600.0}},
        bedtime: %{median_minutes: 1140.0}
      }

      stats = AgeGuide.stats_from(insights)
      assert stats.naps == 3.0
      assert_in_delta stats.nap_minutes, 75.0, 0.01
      assert_in_delta stats.night_hours, 10.0, 0.01
      assert_in_delta stats.total_hours, 13.0, 0.01
      assert stats.bedtime == 1140.0
    end
  end
end
