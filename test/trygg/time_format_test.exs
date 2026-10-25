defmodule Trygg.TimeFormatTest do
  use ExUnit.Case, async: true

  alias Trygg.TimeFormat

  setup do
    on_exit(fn -> TimeFormat.put(:h24) end)
  end

  describe "clock/2" do
    test "24-hour pads the hour" do
      assert TimeFormat.clock(~T[07:05:00], :h24) == "07:05"
      assert TimeFormat.clock(~T[19:05:00], :h24) == "19:05"
    end

    test "12-hour drops the pad and adds AM/PM" do
      assert TimeFormat.clock(~T[07:05:00], :h12) == "7:05 AM"
      assert TimeFormat.clock(~T[19:05:00], :h12) == "7:05 PM"
    end

    test "12-hour midnight and noon read as 12" do
      assert TimeFormat.clock(~T[00:10:00], :h12) == "12:10 AM"
      assert TimeFormat.clock(~T[12:00:00], :h12) == "12:00 PM"
    end

    test "takes minutes since midnight and wraps at a day" do
      assert TimeFormat.clock(19 * 60 + 30, :h24) == "19:30"
      assert TimeFormat.clock(19 * 60 + 30, :h12) == "7:30 PM"
      assert TimeFormat.clock(24 * 60 + 15, :h24) == "00:15"
      assert TimeFormat.clock(-30, :h24) == "23:30"
      assert TimeFormat.clock(450.4, :h24) == "07:30"
    end

    test "formats a DateTime" do
      assert TimeFormat.clock(~U[2026-10-24 21:45:10Z], :h12) == "9:45 PM"
    end

    test "defaults to the process format, 24-hour until one is set" do
      assert TimeFormat.clock(~T[21:45:00]) == "21:45"

      TimeFormat.put(:h12)
      assert TimeFormat.clock(~T[21:45:00]) == "9:45 PM"
      assert TimeFormat.get() == :h12
    end

    test "an unknown format resets to 24-hour" do
      TimeFormat.put(:h12)
      TimeFormat.put(nil)
      assert TimeFormat.get() == :h24
    end
  end

  test "hour_label/2" do
    assert TimeFormat.hour_label(2, :h24) == "02"
    assert TimeFormat.hour_label(0, :h12) == "12a"
    assert TimeFormat.hour_label(2, :h12) == "2a"
    assert TimeFormat.hour_label(12, :h12) == "12p"
    assert TimeFormat.hour_label(22, :h12) == "10p"
  end

  test "end_of_day/1" do
    assert TimeFormat.end_of_day(:h24) == "24:00"
    assert TimeFormat.end_of_day(:h12) == "12:00 AM"
  end

  test "pattern/1 is a strftime pattern" do
    assert Calendar.strftime(~T[15:04:00], TimeFormat.pattern(:h12)) == "3:04 PM"
    assert Calendar.strftime(~T[15:04:00], TimeFormat.pattern(:h24)) == "15:04"
  end
end
