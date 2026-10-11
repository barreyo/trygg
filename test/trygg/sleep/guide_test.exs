defmodule Trygg.Sleep.GuideTest do
  use ExUnit.Case, async: true

  alias Trygg.Sleep.Guide

  test "newborn nights and the evening fuss are there" do
    assert length(Guide.newborn_nights()) >= 5
    assert Enum.any?(Guide.newborn_nights(), &(&1 =~ "20 minutes"))
    assert length(Guide.witching_hours()) >= 3
  end

  test "every phase has topics" do
    for id <- [:newborn, :foundations, :beyond], do: assert(Guide.topics(id) != [])
  end
end
