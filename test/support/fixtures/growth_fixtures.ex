defmodule Trygg.GrowthFixtures do
  @moduledoc "Test helpers for creating growth measurements."

  alias Trygg.Growth

  @doc """
  Creates a growth measurement. `scope` must be a caregiver/owner of `child`.

  Defaults to a 3.2 kg / 50 cm reading on the child's local today.
  """
  def measurement_fixture(scope, child, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put_new("weight_g", 3200.0)
      |> Map.put_new("height_cm", 50.0)

    {:ok, measurement} = Growth.create_measurement(scope, child, attrs)
    measurement
  end
end
