defmodule Trygg.Sleep.SafeSleepTest do
  use ExUnit.Case, async: true

  alias Trygg.Sleep.SafeSleep

  test "item ids are unique and namespaced" do
    ids = SafeSleep.ids()
    assert ids == Enum.uniq(ids)
    assert Enum.all?(ids, &String.starts_with?(&1, "ss-"))
  end

  test "evaluate/1 reads the ticks" do
    result = SafeSleep.evaluate(%{"ss-back" => "2026-10-01", "ss-bare" => "2026-10-01"})
    assert result.done == 2
    assert result.total == length(SafeSleep.items())
    assert Enum.find(result.items, &(&1.id == "ss-back")).checked?
    refute Enum.find(result.items, &(&1.id == "ss-cords")).checked?
  end

  test "evaluate/1 copes with no ticks" do
    assert %{done: 0} = SafeSleep.evaluate(nil)
  end
end
