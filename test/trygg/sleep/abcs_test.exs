defmodule Trygg.Sleep.AbcsTest do
  use ExUnit.Case, async: true

  alias Trygg.Sleep.Abcs

  test "the plan opens at 5 months and runs 14 nights" do
    assert Abcs.min_age_days() == 152
    assert Abcs.nights() == 14
    assert %{id: :abcs, nights: 14, goal_hours: {11, 12}} = Abcs.definition()
  end

  test "pop-ins come after 5 minutes, then 10, then every 15" do
    assert Enum.map(0..5, &Abcs.checkin_interval/1) == [300, 600, 900, 900, 900, 900]
  end

  test "stay 15-20 seconds at a pop-in" do
    assert Abcs.stay_seconds() == {15, 20}
  end

  test "touch on nights 1 and 2, voice only from night 3" do
    assert Abcs.touch(1) == :touch
    assert Abcs.touch(2) == :touch
    assert Abcs.touch(3) == :voice
    assert Abcs.touch(14) == :voice
  end

  test "the goal wake window is 11-12 hours after bedtime" do
    bed = DateTime.new!(~D[2026-10-09], ~T[19:15:00], "Etc/UTC")

    assert Abcs.goal_wake(bed) ==
             {DateTime.new!(~D[2026-10-10], ~T[06:15:00], "Etc/UTC"),
              DateTime.new!(~D[2026-10-10], ~T[07:15:00], "Etc/UTC")}
  end

  test "before 11 hours it's still night; from 11 hours it's morning" do
    bed = DateTime.new!(~D[2026-10-09], ~T[19:15:00], "Etc/UTC")

    assert Abcs.morning_state(bed, DateTime.new!(~D[2026-10-10], ~T[04:30:00], "Etc/UTC")) ==
             :night

    assert Abcs.morning_state(bed, DateTime.new!(~D[2026-10-10], ~T[06:14:59], "Etc/UTC")) ==
             :night

    assert Abcs.morning_state(bed, DateTime.new!(~D[2026-10-10], ~T[06:15:00], "Etc/UTC")) ==
             :morning

    assert Abcs.morning_state(bed, DateTime.new!(~D[2026-10-10], ~T[07:30:00], "Etc/UTC")) ==
             :morning
  end

  test "the pre-flight list has unique ids and starts with the room and the crib" do
    ids = Abcs.preflight_ids()
    assert ids == Enum.uniq(ids)
    assert "p-room" in ids
    assert "p-well" in ids
    assert length(Abcs.preflight()) == length(ids)
  end

  test "the bedtime window is 7-8 pm" do
    assert Abcs.bedtime_window() == {19 * 60, 20 * 60}
  end
end
