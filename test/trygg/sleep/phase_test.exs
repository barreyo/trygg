defmodule Trygg.Sleep.PhaseTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Sleep.Phase

  @today ~D[2026-10-10]

  defp child(days_old, attrs \\ []) do
    struct!(
      %Child{birth_date: Date.add(@today, -days_old), timezone: "Etc/UTC"},
      attrs
    )
  end

  test "a 4 week old is a newborn, in week 4, with Foundations 9 weeks away" do
    assert %{id: :newborn, week: 4, age_days: 28, next: next} = Phase.for_child(child(28), @today)
    assert %{id: :foundations, in_days: 63, on: ~D[2026-12-12]} = next
  end

  test "Foundations starts at 13 weeks and the last phase at about 5 months" do
    assert %{id: :newborn} = Phase.for_child(child(90), @today)
    assert %{id: :foundations, week: 13} = Phase.for_child(child(91), @today)
    assert %{id: :foundations, next: %{id: :beyond}} = Phase.for_child(child(151), @today)
    assert %{id: :beyond, next: nil} = Phase.for_child(child(152), @today)
  end

  test "a baby born early moves through the phases by corrected age" do
    # Born at 32 weeks (224 days): 56 days to the due date, so 91 days old is
    # only 35 days corrected.
    preterm = child(91, gestational_age_days: 224)
    assert %{id: :newborn, age_days: 35, next: %{in_days: 56}} = Phase.for_child(preterm, @today)
  end

  test "timeline gives every phase its start date and state" do
    assert [
             %{id: :newborn, state: :current, starts_on: ~D[2026-09-12]},
             %{id: :foundations, state: :upcoming, starts_on: ~D[2026-12-12]},
             %{id: :beyond, state: :upcoming, starts_on: ~D[2027-02-11]}
           ] = Phase.timeline(child(28), @today)

    assert [%{state: :past}, %{state: :current}, %{state: :upcoming}] =
             Phase.timeline(child(100), @today)

    assert [%{state: :past}, %{state: :past}, %{state: :current}] =
             Phase.timeline(child(200), @today)
  end

  test "no phase without a birth date" do
    assert Phase.for_child(%Child{birth_date: nil, timezone: "Etc/UTC"}, @today) == nil
    assert Phase.timeline(%Child{birth_date: nil, timezone: "Etc/UTC"}, @today) == []
  end
end
