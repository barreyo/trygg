defmodule Trygg.LogFixtures do
  @moduledoc "Test helpers for creating log entries."

  alias Trygg.Log

  @doc """
  Creates a log entry. `scope` must be a caregiver/owner of `child`.

  Pass `:type` (default `:diaper`) and any other attrs understood by
  `Trygg.Log.create_entry/4` (`"data"`, `"started_at"`, `"ended_at"`, `"note"`).
  """
  def entry_fixture(scope, child, attrs \\ %{}) do
    {type, attrs} = Map.pop(Map.new(attrs), :type, :diaper)
    attrs = Map.put_new(attrs, "data", default_data(type))
    {:ok, entry} = Log.create_entry(scope, child, type, attrs)
    entry
  end

  defp default_data(:feeding), do: %{"bottle_contents" => "formula", "amount_ml" => 90}
  defp default_data(:diaper), do: %{"kind" => "pee"}
  defp default_data(:sleep), do: %{"location" => "bassinet"}
  defp default_data(_), do: %{}
end
