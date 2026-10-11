defmodule Trygg.Sleep.NightWeaningTest do
  use ExUnit.Case, async: true

  alias Trygg.Sleep.NightWeaning

  @evening 22 * 60 + 30
  @early 3 * 60 + 30

  defp amounts(table), do: Enum.map(table.rows, & &1.amounts)

  describe "two night feeds" do
    test "the first is dropped on night 4 and the second on night 5, in falling amounts" do
      table = NightWeaning.generate(:nursing, [{@evening, 15}, {@early, 15}])
      [first, second] = amounts(table)

      assert table.nights == 5
      assert [a1, a2, a3, nil, nil] = first
      assert [b1, b2, b3, b4, nil] = second
      assert a1 == 15 and b1 == 15
      assert a1 > a2 and a2 > a3 and a3 >= 1
      assert b1 > b2 and b2 > b3 and b3 > b4 and b4 >= 1
    end

    test "keeps the feed times" do
      table = NightWeaning.generate(:nursing, [{@evening, 10}, {@early, 10}])
      assert Enum.map(table.rows, & &1.time) == [@evening, @early]
    end

    test "a small starting amount still falls every night down to one minute" do
      [first, second] = amounts(NightWeaning.generate(:nursing, [{@evening, 5}, {@early, 5}]))

      assert [5, _, _, nil, nil] = first

      assert Enum.take(second, 4)
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> b < a end)

      assert Enum.all?(Enum.reject(first ++ second, &is_nil/1), &(&1 >= 1))
    end
  end

  describe "bottles" do
    test "amounts are in whole 5 ml steps, falling" do
      [first, second] = amounts(NightWeaning.generate(:bottle, [{@evening, 120}, {@early, 120}]))

      assert hd(first) == 120
      assert Enum.all?(Enum.reject(first ++ second, &is_nil/1), &(rem(&1, 5) == 0))
      assert [_, _, _, nil, nil] = first
      assert [_, _, _, _, nil] = second

      assert first
             |> Enum.reject(&is_nil/1)
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> b < a end)
    end
  end

  describe "one night feed" do
    test "is dropped on night 5 after four falling amounts" do
      table = NightWeaning.generate(:nursing, [{30, 10}])

      assert [[10, a2, a3, a4, nil]] = amounts(table)
      assert 10 > a2 and a2 > a3 and a3 > a4 and a4 >= 1
    end
  end

  describe "three night feeds" do
    test "are dropped on nights 5, 4 and 6 over six nights" do
      table = NightWeaning.generate(:nursing, [{22 * 60, 10}, {60, 5}, {4 * 60, 10}])
      assert table.nights == 6
      [first, second, third] = amounts(table)

      assert Enum.count(first, &is_nil/1) == 2
      assert Enum.count(second, &is_nil/1) == 3
      assert Enum.count(third, &is_nil/1) == 1
      assert List.last(first) == nil and List.last(second) == nil and List.last(third) == nil
      assert Enum.at(second, 3) == nil
      assert Enum.at(first, 3) != nil
    end
  end

  test "needs one to three feeds" do
    assert_raise ArgumentError, fn -> apply(NightWeaning, :generate, [:nursing, []]) end

    assert_raise ArgumentError, fn ->
      NightWeaning.generate(:nursing, List.duplicate({60, 5}, 4))
    end
  end

  test "default times keep the last feed before 11 pm after the first night" do
    assert NightWeaning.default_times(2, 75) == [22 * 60 + 30, 3 * 60 + 30]
    assert NightWeaning.default_times(3, 75) == [22 * 60, 60, 4 * 60]
    # One feed 45 minutes before they naturally wake (1:15 → 0:30).
    assert NightWeaning.default_times(1, 75) == [30]
  end
end
