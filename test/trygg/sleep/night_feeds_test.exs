defmodule Trygg.Sleep.NightFeedsTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Sleep.NightFeeds

  @today ~D[2026-10-10]
  @child %Child{timezone: "Etc/UTC", night_weaning_cleared_on: ~D[2026-10-01]}
  @phase %{id: :foundations, age_days: 100, next: nil}

  defp at(hour, minute \\ 0, date \\ @today),
    do: DateTime.new!(date, Time.new!(hour, minute, 0), "Etc/UTC")

  defp growth(attrs) do
    base = %{
      available?: true,
      latest: %{date: Date.add(@today, -5)},
      velocity: %{percentile_drop?: false, guide_status: :within}
    }

    Map.merge(base, Map.new(attrs))
  end

  describe "gates/4" do
    test "ready when past 13 weeks, weight is on track and the pediatrician is OK'd" do
      gates = NightFeeds.gates(@child, @phase, growth([]), @today)

      assert gates.age == {:ok, nil}
      assert gates.weight == :ok
      assert gates.clearance == ~D[2026-10-01]
      assert gates.ready?
    end

    test "a newborn is locked until 13 weeks, with the date" do
      phase = %{id: :newborn, age_days: 28, next: %{id: :foundations, on: ~D[2026-12-12]}}
      gates = NightFeeds.gates(@child, phase, growth([]), @today)

      assert gates.age == {:locked, ~D[2026-12-12]}
      refute gates.ready?
    end

    test "weight needs a recent weigh-in" do
      stale = growth(latest: %{date: Date.add(@today, -30)})

      assert %{weight: :needs_check, ready?: false} =
               NightFeeds.gates(@child, @phase, stale, @today)

      none = %{available?: false, latest: nil, velocity: nil}
      assert %{weight: :needs_check} = NightFeeds.gates(@child, @phase, none, @today)
    end

    test "weight is flagged when gain is below the guide or dropped across bands" do
      below = growth(velocity: %{percentile_drop?: false, guide_status: :below})
      assert %{weight: :flag, ready?: false} = NightFeeds.gates(@child, @phase, below, @today)

      drop = growth(velocity: %{percentile_drop?: true, guide_status: :within})
      assert %{weight: :flag} = NightFeeds.gates(@child, @phase, drop, @today)
    end

    test "without the pediatrician's go-ahead it isn't ready" do
      child = %{@child | night_weaning_cleared_on: nil}
      gates = NightFeeds.gates(child, @phase, growth([]), @today)
      assert gates.clearance == nil
      refute gates.ready?
    end
  end

  describe "plan/4" do
    defp night(feeds, gap \\ nil) do
      %{
        feeds: length(feeds),
        feed_events: feeds,
        longest_feed_gap_seconds: gap,
        wakings: 0
      }
    end

    defp bottle(hour, minute, ml),
      do: %{at: at(hour, minute), kind: :feeding, ml: ml, minutes: nil}

    defp nursing(hour, minute, minutes),
      do: %{at: at(hour, minute), kind: :breastfeeding, ml: nil, minutes: minutes}

    defp nights(list, baseline \\ nil),
      do: %{nights: list, best_baseline_seconds: baseline, last: List.first(list)}

    test "earliest feed is the last feed plus the baseline, and never under 3 hours" do
      plan = NightFeeds.plan(@child, nights([], 5 * 3600), at(22), at(23))
      assert plan.earliest.at == at(22) |> DateTime.add(5 * 3600)
      assert plan.earliest.state == :wait
      assert plan.earliest.seconds_left == 4 * 3600

      short = NightFeeds.plan(@child, nights([], 3600), at(22), at(22, 30))
      assert short.earliest.at == DateTime.add(at(22), 3 * 3600)

      open = NightFeeds.plan(@child, nights([], 4 * 3600), at(22), at(3, 0, ~D[2026-10-11]))
      assert open.earliest.state == :open
      assert open.earliest.seconds_left == 0
    end

    test "no last feed means no earliest time" do
      assert NightFeeds.plan(@child, nights([]), nil, at(1)).earliest == nil
    end

    test "reduces a bottle by about half an ounce when last night matched the one before" do
      plan =
        NightFeeds.plan(
          @child,
          nights([night([bottle(2, 30, 120)]), night([bottle(2, 30, 120)])]),
          at(1),
          at(2)
        )

      assert plan.action == :reduce
      assert [%{ml: 120, suggested_ml: 105}] = plan.tonight
    end

    test "holds the amount after a reduction last night" do
      plan =
        NightFeeds.plan(
          @child,
          nights([night([bottle(2, 30, 105)]), night([bottle(2, 30, 120)])]),
          at(1),
          at(2)
        )

      assert plan.action == :hold
      assert [%{suggested_ml: 105}] = plan.tonight
    end

    test "nursing comes down 2 minutes at a time" do
      plan =
        NightFeeds.plan(
          @child,
          nights([night([nursing(3, 0, 12)]), night([nursing(3, 0, 12)])]),
          at(1),
          at(2)
        )

      assert plan.action == :reduce
      assert [%{suggested_minutes: 10}] = plan.tonight
    end

    test "never suggests below zero" do
      plan = NightFeeds.plan(@child, nights([night([bottle(2, 0, 10)])]), at(1), at(2))
      assert [%{suggested_ml: 0}] = plan.tonight
    end

    test "the dream feed is left out of the reduction" do
      plan =
        NightFeeds.plan(
          @child,
          nights([
            night([bottle(22, 0, 120), bottle(3, 0, 90)]),
            night([bottle(22, 0, 120), bottle(3, 0, 90)])
          ]),
          at(1),
          at(2)
        )

      assert [%{ml: 90, suggested_ml: 75}] = plan.tonight
    end

    test "no night feeds means nothing to reduce, and the goal is met" do
      plan = NightFeeds.plan(@child, nights([night([]), night([])]), at(1), at(2))
      assert plan.action == :none
      assert plan.tonight == []
      assert plan.goal_met?
    end

    test "the goal is one night feed or fewer on average" do
      one = [night([bottle(2, 0, 90)]), night([bottle(2, 0, 90)])]
      assert NightFeeds.plan(@child, nights(one), at(1), at(2)).goal_met?

      many = [
        night([bottle(1, 0, 90), bottle(4, 0, 90)]),
        night([bottle(2, 0, 90), bottle(5, 0, 90)])
      ]

      refute NightFeeds.plan(@child, nights(many), at(1), at(2)).goal_met?
    end
  end

  describe "typical/1" do
    test "gives the usual night feeds for the age" do
      assert %{label: "0–3 months", average: "3–4", low: "1–2", high: "6"} =
               NightFeeds.typical(30)

      assert %{label: "3–6 months", average: "2–3"} = NightFeeds.typical(100)
      assert %{label: "6–9 months", average: "0–2"} = NightFeeds.typical(200)
      assert %{label: "9–12 months", average: "0–1"} = NightFeeds.typical(300)
      assert %{label: "9–12 months"} = NightFeeds.typical(900)
    end

    test "is nil without an age" do
      assert NightFeeds.typical(nil) == nil
    end
  end

  test "there are rules for deciding which wakings get a feed, and uses for a dream feed" do
    assert length(NightFeeds.rules()) >= 5
    assert length(NightFeeds.dream_feed_uses()) == 3
  end
end
