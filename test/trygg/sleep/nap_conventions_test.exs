defmodule Trygg.Sleep.NapConventionsTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias Trygg.Reports.Day
  alias Trygg.Sleep.NapConventions

  @child %Child{timezone: "Etc/UTC"}

  defp at(date, hour, minute \\ 0),
    do: DateTime.new!(date, Time.new!(hour, minute, 0), "Etc/UTC")

  defp nap(date, hour, minutes, location) do
    start = at(date, hour)
    data = if location, do: %{"location" => location}, else: %{}

    %{
      ordinal: 1,
      running?: false,
      start: start,
      end: DateTime.add(start, minutes * 60),
      seconds: minutes * 60,
      entry: %Entry{type: :sleep, started_at: start, data: data}
    }
  end

  defp day(date, naps, bedtime_hour \\ 19),
    do: %Day{date: date, naps: naps, bedtime: at(date, bedtime_hour)}

  test "the four conventions" do
    assert Enum.map(NapConventions.conventions(), & &1.id) ==
             [:soothing, :consistency, :timing, :independent]
  end

  describe "assess/1" do
    test "place needs five naps with somewhere noted" do
      days = [day(~D[2026-10-01], [nap(~D[2026-10-01], 9, 60, "crib")])]
      assert %{place: nil} = NapConventions.assess(%{child: @child, days: days})
    end

    test "80% in one place is on target" do
      naps = for h <- 8..12, do: nap(~D[2026-10-01], h, 45, "crib")
      naps = naps ++ [nap(~D[2026-10-01], 14, 20, "stroller")]
      assessed = NapConventions.assess(%{child: @child, days: [day(~D[2026-10-01], naps)]})

      assert %{where: "crib", count: 6, ok?: true} = assessed.place
      assert_in_delta assessed.place.share, 5 / 6, 0.001
    end

    test "scattered naps are not" do
      places = ~w(crib stroller contact crib bassinet)
      naps = for {p, h} <- Enum.zip(places, 8..12), do: nap(~D[2026-10-01], h, 45, p)
      assessed = NapConventions.assess(%{child: @child, days: [day(~D[2026-10-01], naps)]})
      refute assessed.place.ok?
    end

    test "counts days a nap ended within 90 minutes of bedtime" do
      late = day(~D[2026-10-01], [nap(~D[2026-10-01], 17, 30, "crib")], 19)
      fine = day(~D[2026-10-02], [nap(~D[2026-10-02], 15, 60, "crib")], 19)
      other = day(~D[2026-10-03], [nap(~D[2026-10-03], 17, 30, "crib")], 19)

      assert %{catnaps: %{days: 2, ok?: false}} =
               NapConventions.assess(%{child: @child, days: [late, fine, other]})

      assert %{catnaps: %{days: 0, ok?: true}} =
               NapConventions.assess(%{child: @child, days: [fine]})
    end
  end

  test "drop_for/1 follows the age" do
    assert NapConventions.drop_for(100).label == "3–6 months"
    assert NapConventions.drop_for(300).label == "6–12 months"
    assert NapConventions.drop_for(400).label == "12–18 months"
    assert NapConventions.drop_for(50) == nil
    assert NapConventions.drop_for(nil) == nil
  end

  test "there are ways to stretch short naps and signs of a nap going" do
    assert Enum.map(NapConventions.short_nap_fixes(), & &1.id) == [:disrupt, :bore]
    assert length(NapConventions.drop_signs()) > 0
    assert length(NapConventions.transition_tips()) > 0
  end
end
