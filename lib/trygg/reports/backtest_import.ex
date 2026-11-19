defmodule Trygg.Reports.BacktestImport do
  @moduledoc """
  Reads a JSON export of children and their log entries back into
  `%Trygg.Families.Child{}` / `%Trygg.Log.Entry{}` structs for
  `Trygg.Reports.Backtest`, so a deployed child's history can be scored on a
  machine with no database.

  The export is `%{"children" => [...], "entries" => [...]}`, as written by the
  command in `Mix.Tasks.Trygg.Backtest`. Anything before the first `{` or after
  the last `}` is ignored (a release `rpc` call prints its return value after
  the JSON).
  """

  alias Trygg.Families.Child
  alias Trygg.Log.Entry

  @types Map.new(Entry.types(), &{Atom.to_string(&1), &1})

  @doc """
  `[{%Child{}, [%Entry{}]}]` from the export text, one per child, entries in
  the order they were exported.
  """
  def parse(text) when is_binary(text) do
    %{"children" => children, "entries" => entries} = text |> extract_json() |> Jason.decode!()
    by_child = entries |> Enum.map(&entry/1) |> Enum.group_by(& &1.child_id)

    for c <- children do
      child = child(c)
      {child, Map.get(by_child, child.id, [])}
    end
  end

  defp extract_json(text) do
    with [from | _] <- :binary.matches(text, "{"),
         [_ | _] = closes <- :binary.matches(text, "}") do
      {start, _} = from
      {stop, _} = List.last(closes)
      binary_part(text, start, stop - start + 1)
    else
      _ -> raise ArgumentError, "no JSON object found in the export"
    end
  end

  defp child(map) do
    %Child{
      id: map["id"],
      name: map["name"],
      timezone: map["timezone"],
      birth_date: date(map["birth_date"]),
      day_start: time(map["day_start"]),
      night_start: time(map["night_start"]),
      gestational_age_days: map["gestational_age_days"]
    }
  end

  defp entry(map) do
    %Entry{
      id: map["id"],
      child_id: map["child_id"],
      type: Map.fetch!(@types, map["type"]),
      started_at: datetime(map["started_at"]),
      ended_at: datetime(map["ended_at"]),
      data: map["data"] || %{}
    }
  end

  defp date(nil), do: nil
  defp date(string), do: Date.from_iso8601!(string)

  defp time(nil), do: nil
  defp time(string), do: Time.from_iso8601!(string)

  defp datetime(nil), do: nil

  defp datetime(string) do
    {:ok, dt, _offset} = DateTime.from_iso8601(string)
    dt
  end
end
