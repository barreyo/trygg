defmodule Trygg.Reports.DayTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias Trygg.Reports.Day

  defp child do
    %Child{
      timezone: "Etc/UTC",
      day_start: ~T[08:00:00],
      night_start: ~T[20:00:00]
    }
  end

  defp sleep(id, start, finish) do
    %Entry{
      id: id,
      type: :sleep,
      started_at: start,
      ended_at: finish,
      data: %{"location" => "crib"}
    }
  end

  defp feed(id, at, ml) do
    %Entry{
      id: id,
      type: :feeding,
      started_at: at,
      ended_at: at,
      data: %{"amount_ml" => ml * 1.0, "bottle_contents" => "formula"}
    }
  end

  defp diaper(id, at) do
    %Entry{
      id: id,
      type: :diaper,
      started_at: at,
      ended_at: nil,
      data: %{"kind" => "pee"}
    }
  end

  describe "calendar segmentation" do
    test "clips a sleep that spans midnight onto the local day" do
      date = ~D[2026-03-02]
      now = ~U[2026-03-03 12:00:00Z]
      overnight = sleep(1, ~U[2026-03-01 20:30:00Z], ~U[2026-03-02 07:00:00Z])

      day = Day.build(child(), date, [overnight], now)
      [seg] = day.sleep_segments

      assert seg.start == ~U[2026-03-02 00:00:00Z]
      assert seg.end == ~U[2026-03-02 07:00:00Z]
      assert seg.seconds == 7 * 3600
      refute seg.running?
    end

    test "a running sleep extends to now and is clipped to the day" do
      date = ~D[2026-03-02]
      now = ~U[2026-03-02 10:15:00Z]
      running = sleep(1, ~U[2026-03-02 09:00:00Z], nil)

      day = Day.build(child(), date, [running], now)
      [seg] = day.sleep_segments

      assert seg.start == ~U[2026-03-02 09:00:00Z]
      assert seg.end == now
      assert seg.running?
      assert day.now?
      assert day.now_offset == 10 * 3600 + 15 * 60
    end

    test "wake segments fill the gaps, stopping at now on the current day" do
      date = ~D[2026-03-02]
      now = ~U[2026-03-02 12:00:00Z]
      nap = sleep(1, ~U[2026-03-02 10:00:00Z], ~U[2026-03-02 11:00:00Z])

      day = Day.build(child(), date, [nap], now)
      [w1, w2] = day.wake_segments

      assert w1.start == ~U[2026-03-02 00:00:00Z]
      assert w1.end == ~U[2026-03-02 10:00:00Z]
      assert w1.first?
      assert w2.start == ~U[2026-03-02 11:00:00Z]
      assert w2.end == now
      assert w2.last?
    end

    test "splits sleep into day and night using the child's boundaries" do
      date = ~D[2026-03-02]
      now = ~U[2026-03-03 12:00:00Z]

      entries = [
        sleep(1, ~U[2026-03-02 06:00:00Z], ~U[2026-03-02 09:00:00Z]),
        sleep(2, ~U[2026-03-02 21:00:00Z], ~U[2026-03-02 23:00:00Z])
      ]

      day = Day.build(child(), date, entries, now)
      # 06:00-08:00 night (2h) + 08:00-09:00 day (1h) + 21:00-23:00 night (2h)
      assert day.day_sleep_seconds == 3600
      assert day.night_sleep_seconds == 4 * 3600
      assert day.total_sleep_seconds == 5 * 3600
    end

    test "places feed and diaper markers on the day they occurred" do
      date = ~D[2026-03-02]
      now = ~U[2026-03-03 12:00:00Z]

      entries = [
        feed(10, ~U[2026-03-02 11:00:00Z], 120),
        diaper(11, ~U[2026-03-02 11:30:00Z]),
        feed(12, ~U[2026-03-01 11:00:00Z], 90)
      ]

      day = Day.build(child(), date, entries, now)
      assert length(day.feeds) == 1
      assert hd(day.feeds).data["amount_ml"] == 120.0
      assert length(day.diapers) == 1
    end
  end

  describe "overnight cluster" do
    test "detects bedtime, morning wake, and a night waking" do
      date = ~D[2026-03-02]
      now = ~U[2026-03-03 12:00:00Z]

      entries = [
        sleep(1, ~U[2026-03-01 20:00:00Z], ~U[2026-03-02 02:00:00Z]),
        sleep(2, ~U[2026-03-02 02:30:00Z], ~U[2026-03-02 07:00:00Z]),
        sleep(3, ~U[2026-03-02 20:15:00Z], ~U[2026-03-03 07:10:00Z])
      ]

      day = Day.build(child(), date, entries, now)
      assert day.morning_wake == ~U[2026-03-02 07:00:00Z]
      assert day.bedtime == ~U[2026-03-02 20:15:00Z]
      assert day.night_wakings == []

      yesterday = Day.build(child(), ~D[2026-03-01], entries, now)
      assert yesterday.bedtime == ~U[2026-03-01 20:00:00Z]
      assert [waking] = yesterday.night_wakings
      assert waking.seconds == 30 * 60
    end

    test "a feed logged while the sleep timer ran counts as a night waking" do
      date = ~D[2026-03-01]
      now = ~U[2026-03-03 12:00:00Z]

      entries = [
        sleep(1, ~U[2026-03-01 20:00:00Z], ~U[2026-03-02 02:00:00Z]),
        sleep(2, ~U[2026-03-02 02:30:00Z], ~U[2026-03-02 07:00:00Z]),
        # Timer left on through a 23:30 feed, topped up ten minutes later.
        feed(10, ~U[2026-03-01 23:30:00Z], 90),
        feed(11, ~U[2026-03-01 23:40:00Z], 30),
        # In the 02:00-02:30 gap: already counted as that waking.
        feed(12, ~U[2026-03-02 02:15:00Z], 120)
      ]

      day = Day.build(child(), date, entries, now)

      assert [feed_waking, gap_waking] = day.night_wakings
      assert feed_waking.start == ~U[2026-03-01 23:30:00Z]
      assert feed_waking.seconds == nil
      assert gap_waking.seconds == 30 * 60
    end

    test "bedtime and morning bottles at the edges of a sleep are not wakings" do
      date = ~D[2026-03-01]
      now = ~U[2026-03-03 12:00:00Z]

      entries = [
        sleep(1, ~U[2026-03-01 20:00:00Z], ~U[2026-03-02 07:00:00Z]),
        feed(10, ~U[2026-03-01 20:05:00Z], 120),
        feed(11, ~U[2026-03-02 06:50:00Z], 120)
      ]

      assert Day.build(child(), date, entries, now).night_wakings == []
    end

    test "a feed just logged during a running sleep is a waking now" do
      date = ~D[2026-03-01]
      now = ~U[2026-03-02 01:05:00Z]

      entries = [
        sleep(1, ~U[2026-03-01 20:00:00Z], nil),
        feed(10, ~U[2026-03-02 01:00:00Z], 90)
      ]

      assert [%{start: ~U[2026-03-02 01:00:00Z]}] =
               Day.build(child(), date, entries, now).night_wakings
    end

    test "a long gap makes two clusters; the overnight one wins" do
      date = ~D[2026-03-02]
      now = ~U[2026-03-03 12:00:00Z]

      entries = [
        sleep(1, ~U[2026-03-02 16:00:00Z], ~U[2026-03-02 16:40:00Z]),
        sleep(2, ~U[2026-03-02 20:30:00Z], ~U[2026-03-03 07:00:00Z])
      ]

      day = Day.build(child(), date, entries, now)
      assert day.bedtime == ~U[2026-03-02 20:30:00Z]
      assert [%{ordinal: 1, start: ~U[2026-03-02 16:00:00Z]}] = day.naps
    end

    test "a short daytime gap is a nap, not more overnight sleep" do
      date = ~D[2026-03-02]
      now = ~U[2026-03-03 12:00:00Z]

      entries = [
        sleep(1, ~U[2026-03-01 20:00:00Z], ~U[2026-03-02 07:00:00Z]),
        sleep(2, ~U[2026-03-02 08:00:00Z], ~U[2026-03-02 09:10:00Z]),
        sleep(3, ~U[2026-03-02 10:20:00Z], ~U[2026-03-02 11:15:00Z]),
        sleep(4, ~U[2026-03-02 20:00:00Z], ~U[2026-03-03 07:00:00Z])
      ]

      day = Day.build(child(), date, entries, now)
      assert day.morning_wake == ~U[2026-03-02 07:00:00Z]
      assert day.bedtime == ~U[2026-03-02 20:00:00Z]
      assert Enum.map(day.naps, & &1.id) == [2, 3]

      assert Enum.map(day.wake_windows, &{&1.ordinal, &1.seconds}) == [
               {1, 3600},
               {2, DateTime.diff(~U[2026-03-02 10:20:00Z], ~U[2026-03-02 09:10:00Z], :second)},
               {3, DateTime.diff(~U[2026-03-02 20:00:00Z], ~U[2026-03-02 11:15:00Z], :second)}
             ]
    end

    test "short evening catnaps still join bedtime" do
      date = ~D[2026-03-02]
      now = ~U[2026-03-03 12:00:00Z]

      entries = [
        sleep(1, ~U[2026-03-01 20:00:00Z], ~U[2026-03-02 07:00:00Z]),
        sleep(2, ~U[2026-03-02 18:30:00Z], ~U[2026-03-02 18:50:00Z]),
        sleep(3, ~U[2026-03-02 19:15:00Z], ~U[2026-03-02 19:40:00Z]),
        sleep(4, ~U[2026-03-02 20:00:00Z], ~U[2026-03-03 07:00:00Z])
      ]

      day = Day.build(child(), date, entries, now)
      assert day.bedtime == ~U[2026-03-02 18:30:00Z]
      assert day.naps == []
    end
  end

  describe "naps and wake windows" do
    test "numbers naps and wake windows between morning wake and bedtime" do
      date = ~D[2026-03-02]
      now = ~U[2026-03-03 12:00:00Z]

      entries = [
        sleep(1, ~U[2026-03-01 20:00:00Z], ~U[2026-03-02 07:30:00Z]),
        sleep(2, ~U[2026-03-02 10:00:00Z], ~U[2026-03-02 11:00:00Z]),
        sleep(3, ~U[2026-03-02 14:00:00Z], ~U[2026-03-02 15:30:00Z]),
        sleep(4, ~U[2026-03-02 19:45:00Z], ~U[2026-03-03 07:00:00Z])
      ]

      day = Day.build(child(), date, entries, now)

      assert Enum.map(day.naps, & &1.ordinal) == [1, 2]
      assert Enum.map(day.naps, & &1.seconds) == [3600, 90 * 60]

      assert Enum.map(day.wake_windows, &{&1.ordinal, &1.seconds, &1.open?}) == [
               {1, DateTime.diff(~U[2026-03-02 10:00:00Z], ~U[2026-03-02 07:30:00Z], :second),
                false},
               {2, DateTime.diff(~U[2026-03-02 14:00:00Z], ~U[2026-03-02 11:00:00Z], :second),
                false},
               {3, DateTime.diff(~U[2026-03-02 19:45:00Z], ~U[2026-03-02 15:30:00Z], :second),
                false}
             ]
    end

    test "an open last wake window is marked when bedtime hasn't happened" do
      date = ~D[2026-03-02]
      now = ~U[2026-03-02 16:00:00Z]

      entries = [
        sleep(1, ~U[2026-03-01 20:00:00Z], ~U[2026-03-02 07:00:00Z]),
        sleep(2, ~U[2026-03-02 10:00:00Z], ~U[2026-03-02 11:00:00Z])
      ]

      day = Day.build(child(), date, entries, now)
      last = List.last(day.wake_windows)
      assert last.open?
      assert last.end == now
      assert is_nil(day.bedtime)
    end
  end
end
