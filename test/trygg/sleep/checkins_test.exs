defmodule Trygg.Sleep.CheckinsTest do
  use ExUnit.Case, async: true

  alias Trygg.Sleep.Checkins

  @t0 ~U[2026-10-10 02:00:00Z]

  defp at(minutes, seconds \\ 0), do: DateTime.add(@t0, minutes * 60 + seconds, :second)
  defp ev(kind, minutes), do: Checkins.event(kind, at(minutes))
  defp state(events, now_minutes), do: Checkins.state(events, at(now_minutes))

  test "no events yet" do
    assert %{phase: :waiting, next_due_at: nil, cry_seconds: 0, pop_ins: 0} = state([], 5)
  end

  test "event/2 rejects unknown kinds" do
    assert_raise FunctionClauseError, fn -> Checkins.event("shout", @t0) end
  end

  describe "the pop-in schedule" do
    test "the first is due 5 minutes after the crying starts" do
      assert %{phase: :crying, next_due_at: due, pop_ins: 0} = state([ev("cry", 0)], 2)
      assert due == at(5)
    end

    test "the second is 10 minutes after the first, then 15 after each" do
      events = [ev("cry", 0), ev("pop_in", 5)]
      assert %{next_due_at: due, pop_ins: 1} = state(events, 6)
      assert due == at(15)

      events = events ++ [ev("pop_in", 15)]
      assert %{next_due_at: due, pop_ins: 2} = state(events, 16)
      assert due == at(30)

      events = events ++ [ev("pop_in", 31)]
      assert %{next_due_at: due, pop_ins: 3} = state(events, 32)
      assert due == at(46)
    end

    test "lists the pop-in times" do
      events = [ev("cry", 0), ev("pop_in", 5), ev("pop_in", 15)]
      assert %{pop_in_times: [t1, t2]} = state(events, 20)
      assert {t1, t2} == {at(5), at(15)}
    end
  end

  describe "calming" do
    test "calming pauses the schedule: nothing is due" do
      events = [ev("cry", 0), ev("calm", 3)]
      assert %{phase: :calming, next_due_at: nil} = state(events, 10)
    end

    test "crying again resumes counting from then, keeping the pop-in count" do
      events = [ev("cry", 0), ev("pop_in", 5), ev("calm", 8), ev("cry", 12)]
      assert %{phase: :crying, pop_ins: 1, next_due_at: due} = state(events, 13)
      # The second interval (10 minutes) from when they started crying again.
      assert due == at(22)
    end
  end

  describe "crying time" do
    test "counts from the cry to now while it goes on" do
      assert %{cry_seconds: 420} = state([ev("cry", 0), ev("pop_in", 5)], 7)
    end

    test "stops when they calm and starts again with the next cry" do
      events = [ev("cry", 0), ev("calm", 4), ev("cry", 10)]
      assert %{cry_seconds: 420} = state(events, 13)
    end

    test "a pop-in doesn't stop the clock; sleeping does" do
      events = [ev("cry", 0), ev("pop_in", 5), ev("pop_in", 15), ev("asleep", 22)]
      assert %{phase: :asleep, cry_seconds: 1320, next_due_at: nil} = state(events, 60)
    end

    test "a waking they were never upset in has no crying" do
      assert %{cry_seconds: 0, phase: :asleep} = state([ev("asleep", 10)], 20)
    end

    test "extra cry events while already crying change nothing" do
      assert %{cry_seconds: 300} = state([ev("cry", 0), ev("cry", 2)], 5)
    end
  end

  test "reports when it started and when they fell asleep" do
    assert %{started_at: s, asleep_at: a} = state([ev("cry", 1), ev("asleep", 9)], 20)
    assert {s, a} == {at(1), at(9)}
  end
end
