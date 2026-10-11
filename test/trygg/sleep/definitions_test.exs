defmodule Trygg.Sleep.DefinitionsTest do
  use ExUnit.Case, async: true

  alias Trygg.Sleep.{Definitions, Plan}

  test "gentlest first" do
    assert Definitions.ids() == [:swap, :slip, :abcs]
  end

  test "ages" do
    assert Definitions.min_age_days(:swap) == 61
    assert Definitions.min_age_days(:slip) == 122
    assert Definitions.min_age_days(:abcs) == 152
  end

  test "a SWAP cuts nothing so needs no go-ahead; the others do" do
    refute Definitions.needs_clearance?(:swap)
    assert Definitions.needs_clearance?(:slip)
    assert Definitions.needs_clearance?(:abcs)
  end

  test "pre-flight ids don't collide between plans" do
    ids = Definitions.all_preflight_ids()
    assert ids == Enum.uniq(ids)
    assert length(ids) == 5 + 10 + 8
  end

  test "nights" do
    assert Definitions.nights(%Plan{definition: :abcs}) == 14
    assert Definitions.nights(%Plan{definition: nil}) == 14
    assert Definitions.nights(%Plan{definition: :slip}) == 7
    assert Definitions.nights(%Plan{definition: :swap, options: %{"variant" => "chair"}}) == 10
    assert Definitions.nights(%Plan{definition: :swap, options: %{"variant" => "pat"}}) == 7
  end

  describe "schedule/2" do
    test "ABCs pop-ins" do
      assert Definitions.schedule(%Plan{definition: :abcs}, 3) == :abcs
      assert Definitions.schedule(%Plan{definition: nil}, 3) == :abcs
    end

    test "graduated SLIP grows with the night, full has no visits" do
      graduated = %Plan{definition: :slip, options: %{"mode" => "graduated"}}
      assert Definitions.schedule(graduated, 3) == {:five_minute, 3}
      assert Definitions.schedule(graduated, 0) == {:five_minute, 1}

      full = %Plan{definition: :slip, options: %{"mode" => "full"}}
      assert Definitions.schedule(full, 3) == :none
    end

    test "a SWAP isn't timed" do
      assert Definitions.schedule(%Plan{definition: :swap}, 2) == :manual
    end
  end

  test "a full SLIP has no visits to record" do
    refute Definitions.visits?(%Plan{definition: :slip, options: %{"mode" => "full"}})
    assert Definitions.visits?(%Plan{definition: :slip, options: %{"mode" => "graduated"}})
    assert Definitions.visits?(%Plan{definition: :swap, options: %{}})
    assert Definitions.visits?(%Plan{definition: :abcs})
  end
end
