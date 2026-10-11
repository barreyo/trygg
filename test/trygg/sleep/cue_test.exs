defmodule Trygg.Sleep.CueTest do
  use ExUnit.Case, async: true

  alias Trygg.Sleep.Cue

  test "the three cues from the sleepy cues sheet, least to most tired" do
    assert Cue.ids() == ["tired", "ready", "overtired"]
  end

  test "valid?/1, label/1 and short/1" do
    assert Cue.valid?("ready")
    refute Cue.valid?("hungry")
    refute Cue.valid?(nil)

    assert Cue.label("overtired") == "Overtired"
    assert Cue.short("tired") == "Tired cues"
    assert Cue.label("nope") == nil
  end

  test "every cue lists its signs" do
    for cue <- Cue.all(), do: assert([_ | _] = cue.signs)
  end
end
