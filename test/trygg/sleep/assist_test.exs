defmodule Trygg.Sleep.AssistTest do
  use ExUnit.Case, async: true

  alias Trygg.Sleep.Assist

  test "nine levels, most help first" do
    assert Enum.map(Assist.levels(), &elem(&1, 0)) == Enum.to_list(1..9)
    assert Assist.label(1) =~ "Fed"
    assert Assist.label(9) =~ "independently"
  end

  test "valid?/1 accepts only whole levels 1-9" do
    assert Assist.valid?(1) and Assist.valid?(9)
    refute Assist.valid?(0)
    refute Assist.valid?(10)
    refute Assist.valid?("5")
    refute Assist.valid?(nil)
  end

  test "next_step/1 moves one step toward less help, and stops at the end" do
    assert Assist.next_step(3) == 4
    assert Assist.next_step(8) == 9
    assert Assist.next_step(9) == nil
    assert Assist.next_step(nil) == nil
  end

  test "settle buckets have labels" do
    assert Assist.settle_label(10) == "5–10 min"
    assert Assist.settle_label(7) == nil
    assert Assist.short(7) == "Level 7"
  end
end
