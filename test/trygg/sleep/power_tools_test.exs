defmodule Trygg.Sleep.PowerToolsTest do
  use ExUnit.Case, async: true

  alias Trygg.Sleep.PowerTools

  defp tool(tools, id), do: Enum.find(tools, &(&1.id == id))

  test "there are four tools" do
    assert PowerTools.plan(30) |> Enum.map(& &1.id) ==
             [:white_noise, :swaddle, :pacifier, :schedule]
  end

  describe "swaddle" do
    test "is fine for a newborn" do
      assert %{state: :use} = tool(PowerTools.plan(20), :swaddle)
    end

    test "starts to wind down after two months" do
      assert %{state: :consider} = tool(PowerTools.plan(90), :swaddle)
    end

    test "is over by four months" do
      assert %{state: :stop} = tool(PowerTools.plan(130), :swaddle)
    end

    test "stops at once when they're rolling, whatever the age" do
      swaddle = tool(PowerTools.plan(20, %{"pt-rolling" => "2026-10-01"}), :swaddle)
      assert swaddle.state == :stop
      assert swaddle.headline =~ "now"
    end

    test "escaping gets a different blanket first" do
      swaddle = tool(PowerTools.plan(80, %{"pt-swaddle-escapes" => "2026-10-01"}), :swaddle)
      assert swaddle.state == :consider
      assert swaddle.headline =~ "different"
    end
  end

  describe "pacifier" do
    test "is encouraged for a young baby" do
      assert %{state: :use} = tool(PowerTools.plan(40), :pacifier)
    end

    test "the easiest time to drop it is around four to five months" do
      assert %{state: :consider} = tool(PowerTools.plan(140), :pacifier)
    end

    test "is dropped once it needs putting back through the night" do
      assert %{state: :stop} =
               tool(PowerTools.plan(220, %{"pt-paci-night" => "2026-10-01"}), :pacifier)
    end

    test "is on its way out before two and gone after" do
      assert %{state: :consider} = tool(PowerTools.plan(500), :pacifier)
      assert %{state: :stop} = tool(PowerTools.plan(800), :pacifier)
    end
  end

  test "white noise is for the whole first year, then optional" do
    assert %{state: :use} = tool(PowerTools.plan(200), :white_noise)
    assert %{state: :optional} = tool(PowerTools.plan(400), :white_noise)
  end

  test "an unknown age is handled" do
    assert [_, _, _, _] = PowerTools.plan(nil)
  end

  test "the lovey waits for a year" do
    assert PowerTools.lovey_note(100) =~ "Nothing soft"
    assert PowerTools.lovey_note(400) =~ "lovey"
    refute PowerTools.lovey_note(400) =~ "Nothing soft"
  end
end
