defmodule Trygg.Reports.AlertsTest do
  use ExUnit.Case, async: true

  alias Trygg.Reports.Alerts

  defp diapers(flags, overrides \\ %{}) do
    Map.merge(
      %{
        flags: flags,
        dry_seconds: 7 * 3600,
        min_wet: 6,
        today: %{wet: 1, expected_wet_by_now: 4.0},
        yesterday: %{wet: 3, total: 3},
        baseline: %{wet: %{median: 7.0}}
      },
      overrides
    )
  end

  defp shifts(overrides \\ %{}) do
    Map.merge(%{sleep: [], feeding: [], growth_burst: %{active?: false}}, overrides)
  end

  test "returns an empty list when nothing is flagged" do
    assert Alerts.build(%{feeding: nil, diapers: nil, shifts: nil, growth: nil}) == []
    assert Alerts.build(%{diapers: diapers([]), shifts: shifts()}) == []
  end

  test "hydration flags become warnings and notices, ordered by severity" do
    alerts = Alerts.build(%{diapers: diapers([:low_wet_pace, :no_wet_6h])})

    assert Enum.map(alerts, & &1.id) == ["no-wet-diaper", "low-wet-pace"]
    assert hd(alerts).severity == :warning
    assert hd(alerts).title =~ "7h"
    assert List.last(alerts).detail =~ "about 4"
  end

  test "feeding more with normal diapers is informational; with fewer wet diapers it is a notice" do
    up = %{metric: :feeds, direction: :up, recent_median: 9.0, baseline_median: 6.0, delta: 3.0}

    [alert] = Alerts.build(%{shifts: shifts(%{feeding: [up]}), diapers: diapers([])})
    assert alert.id == "feeding-check"
    assert alert.severity == :info
    assert alert.title == "Eating more than usual"

    alerts = Alerts.build(%{shifts: shifts(%{feeding: [up]}), diapers: diapers([:low_wet_day])})
    check = Enum.find(alerts, &(&1.id == "feeding-check"))
    assert check.severity == :notice
    assert check.title =~ "fewer wet diapers"
  end

  test "sleep shift copy never says regression and lists the findings" do
    finding = %{
      metric: :night_wakings,
      direction: :up,
      recent_median: 3.0,
      baseline_median: 1.0,
      delta: 2.0
    }

    [alert] = Alerts.build(%{shifts: shifts(%{sleep: [finding]})})
    assert alert.id == "sleep-shift"
    assert alert.severity == :notice
    assert alert.title == "Sleep shift"
    assert alert.detail =~ "Night wakings up: ~3 vs usual ~1"
    refute alert.detail =~ ~r/regress/i
    assert alert.link == :reports
  end

  test "growth burst points to Vitals with the study framing" do
    burst = %{
      active?: true,
      sleep_days: 1,
      nap_days: 0,
      extra_sleep_seconds: 3 * 3600,
      extra_naps: 0,
      feed_pct: 25.0,
      feed_up?: true,
      on: ~D[2026-03-19]
    }

    [alert] = Alerts.build(%{shifts: shifts(%{growth_burst: burst})})
    assert alert.id == "growth-burst"
    assert alert.severity == :info
    assert alert.detail =~ "3h more sleep"
    assert alert.detail =~ "25% more milk"
    assert alert.detail =~ "Lampl"
    assert alert.link == :vitals
  end

  test "newborn loss and percentile drop come from the growth summary" do
    growth = %{
      newborn: %{
        loss_flag?: true,
        loss_pct: 11.2,
        regain_overdue?: false,
        latest_pct_of_birth: 92.0
      },
      velocity: %{percentile_drop?: true, percentile_prev: 50, percentile_now: 25, days: 21}
    }

    alerts = Alerts.build(%{growth: growth})
    assert Enum.map(alerts, & &1.id) == ["newborn-weight-loss", "percentile-drop"]
    assert hd(alerts).title =~ "11.2%"
    assert List.last(alerts).detail =~ "50th to the 25th"
  end

  test "intake below the guide is informational and unit-aware" do
    feeding = %{
      intake: %{
        status: :below,
        avg_ml: 540.0,
        avg_days: 3,
        ml_per_kg: 135.0,
        guide_per_kg: {150, 180}
      }
    }

    [alert] = Alerts.build(%{feeding: feeding}, unit_system: :imperial)
    assert alert.id == "intake-below-guide"
    assert alert.severity == :info
    assert alert.detail =~ "oz"
    assert alert.detail =~ "150–180 ml/kg"
  end
end
