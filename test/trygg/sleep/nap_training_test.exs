defmodule Trygg.Sleep.NapTrainingTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Sleep.NapTraining

  @child %Child{timezone: "Etc/UTC", sleep_checks: %{}}

  defp night(wake, bed_hours) do
    bedtime = DateTime.add(wake, -round(bed_hours * 3600), :second)
    %{bedtime: bedtime, wake: wake}
  end

  defp ctx(attrs \\ []) do
    %{child: @child, nights: %{nights: []}, nap_medians: [], age_days: 200}
    |> Map.merge(Map.new(attrs))
  end

  defp sign(result, id), do: Enum.find(result.signs, &(&1.id == id))

  test "six signs, three of them ticked from the log" do
    result = NapTraining.readiness(ctx())
    assert length(result.signs) == 6

    assert result.signs |> Enum.filter(& &1.auto?) |> Enum.map(& &1.id) |> Enum.sort() == [
             "n-age",
             "n-early",
             "n-nights",
             "n-short"
           ]

    refute result.any?
  end

  test "ten months or older" do
    assert sign(NapTraining.readiness(ctx(age_days: 320)), "n-age").checked?
    refute sign(NapTraining.readiness(ctx(age_days: 303)), "n-age").checked?
    refute sign(NapTraining.readiness(ctx(age_days: nil)), "n-age").checked?
  end

  test "11-12 hours a night on 10 of the last 14 nights" do
    wake = ~U[2026-10-10 06:30:00Z]
    long = for i <- 1..10, do: night(DateTime.add(wake, -i * 86_400, :second), 11.5)
    short = for i <- 11..14, do: night(DateTime.add(wake, -i * 86_400, :second), 9)

    assert %{checked?: true, detail: "10 of the last 14 nights"} =
             sign(NapTraining.readiness(ctx(nights: %{nights: long ++ short})), "n-nights")

    nine = Enum.take(long, 9) ++ short
    refute sign(NapTraining.readiness(ctx(nights: %{nights: nine})), "n-nights").checked?

    refute sign(NapTraining.readiness(ctx(nights: %{nights: Enum.take(long, 5)})), "n-nights").checked?
  end

  test "early mornings: three of the last seven before 5:30" do
    early =
      for d <- 1..3, do: night(DateTime.new!(Date.new!(2026, 10, d), ~T[04:50:00], "Etc/UTC"), 10)

    fine =
      for d <- 4..7, do: night(DateTime.new!(Date.new!(2026, 10, d), ~T[06:40:00], "Etc/UTC"), 11)

    assert sign(NapTraining.readiness(ctx(nights: %{nights: early ++ fine})), "n-early").checked?

    refute sign(
             NapTraining.readiness(ctx(nights: %{nights: Enum.take(early, 2) ++ fine})),
             "n-early"
           ).checked?
  end

  test "short naps: every typical nap under 40 minutes" do
    assert sign(NapTraining.readiness(ctx(nap_medians: [1800, 2100])), "n-short").checked?
    refute sign(NapTraining.readiness(ctx(nap_medians: [1800, 3600])), "n-short").checked?
    refute sign(NapTraining.readiness(ctx(nap_medians: [])), "n-short").checked?
  end

  test "the other signs follow the hand ticks, and any one is enough" do
    child = %{@child | sleep_checks: %{"n-battle" => "2026-10-10"}}
    result = NapTraining.readiness(ctx(child: child))

    assert sign(result, "n-battle").checked?
    refute sign(result, "n-day-sleep").checked?
    assert result.any?
  end

  test "content: three N.A.P. steps and tips" do
    assert Enum.map_join(NapTraining.steps(), & &1.letter) == "NAP"
    assert length(NapTraining.tips()) >= 4
    assert Enum.map(NapTraining.signs(), &elem(&1, 0)) |> Enum.uniq() |> length() == 6
  end
end
