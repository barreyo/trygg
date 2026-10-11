defmodule Trygg.Sleep.MethodsTest do
  use ExUnit.Case, async: true

  alias Trygg.Sleep.Methods

  test "S.I.T. B.A.C.K. has seven steps spelling the acronym, the last untimed" do
    %{steps: steps} = Methods.get(:sit_back)

    assert Enum.map_join(steps, & &1.letter) == "SITBACK"
    assert List.last(steps).seconds == nil
    assert Enum.all?(Enum.drop(steps, -1), &is_integer(&1.seconds))
  end

  test "the steps use the guide's times: 5-8 minutes to stop and watch, then 2 minutes each" do
    [stop, sound, touch, binky, rocking, cuddle, _feed] = Methods.get(:sit_back).steps

    assert {stop.seconds, stop.max_seconds} == {300, 480}

    assert Enum.map([sound, touch, binky, rocking, cuddle], & &1.seconds) ==
             List.duplicate(120, 5)
  end

  test "C.R.I.E.S. has five untimed steps" do
    %{steps: steps} = Methods.get(:cries)
    assert Enum.map_join(steps, & &1.letter) == "CRIES"
    assert Enum.all?(steps, &is_nil(&1.seconds))
  end

  test "step/2 and count/1" do
    assert %{letter: "S"} = Methods.step(:sit_back, 0)
    assert %{letter: "K"} = Methods.step(:sit_back, 6)
    assert Methods.step(:sit_back, 7) == nil
    assert Methods.step(:nope, 0) == nil
    assert Methods.count(:sit_back) == 7
    assert Methods.count(:cries) == 5
    assert Methods.count(:nope) == 0
  end

  test "a newborn gets C.R.I.E.S. and everyone after gets S.I.T. B.A.C.K." do
    assert Methods.for_phase(:newborn) == :cries
    assert Methods.for_phase(:foundations) == :sit_back
    assert Methods.for_phase(:beyond) == :sit_back
  end
end
