defmodule Trygg.Reports.BacktestImportTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias Trygg.Reports.Backtest
  alias Trygg.Reports.BacktestImport

  defp export(children, entries) do
    Jason.encode!(%{
      children:
        Enum.map(
          children,
          &Map.take(&1, [
            :id,
            :name,
            :birth_date,
            :timezone,
            :day_start,
            :night_start,
            :gestational_age_days
          ])
        ),
      entries:
        Enum.map(entries, &Map.take(&1, [:id, :child_id, :type, :started_at, :ended_at, :data]))
    })
  end

  defp child(id, name) do
    %Child{
      id: id,
      name: name,
      timezone: "Etc/UTC",
      birth_date: ~D[2026-02-01],
      day_start: ~T[08:00:00],
      night_start: ~T[20:00:00],
      gestational_age_days: 280
    }
  end

  defp sleep(id, child_id, start, finish) do
    %Entry{
      id: id,
      child_id: child_id,
      type: :sleep,
      started_at: start,
      ended_at: finish,
      data: %{}
    }
  end

  test "round-trips children and entries, grouped per child" do
    a = child(1, "Astrid")
    b = child(2, "Other")

    entries = [
      sleep(1, 1, ~U[2026-03-01 09:30:00Z], ~U[2026-03-01 10:30:00Z]),
      %Entry{
        id: 2,
        child_id: 1,
        type: :feeding,
        started_at: ~U[2026-03-01 11:00:00Z],
        ended_at: nil,
        data: %{"amount_ml" => 90}
      },
      sleep(3, 2, ~U[2026-03-01 13:00:00Z], nil)
    ]

    assert [{pa, ea}, {pb, eb}] = BacktestImport.parse(export([a, b], entries))

    assert %Child{id: 1, name: "Astrid", timezone: "Etc/UTC", gestational_age_days: 280} = pa
    assert pa.birth_date == ~D[2026-02-01]
    assert pa.night_start == ~T[20:00:00]
    assert Enum.map(ea, &{&1.id, &1.type}) == [{1, :sleep}, {2, :feeding}]
    assert Enum.at(ea, 0).started_at == ~U[2026-03-01 09:30:00Z]
    assert Enum.at(ea, 1).data == %{"amount_ml" => 90}
    assert pb.id == 2
    assert [%Entry{id: 3, ended_at: nil}] = eb
  end

  test "ignores what a release rpc prints around the JSON" do
    json = export([child(1, "Astrid")], [])
    assert [{%Child{name: "Astrid"}, []}] = BacktestImport.parse(json <> "\n:ok\n")
  end

  test "complains when there is no JSON" do
    assert_raise ArgumentError, fn -> BacktestImport.parse("nothing here") end
  end

  test "an imported export can be backtested" do
    entries =
      for date <- Date.range(~D[2026-02-28], ~D[2026-03-25]),
          {{from, to}, n} <-
            Enum.with_index([
              {{date, ~T[09:30:00]}, {date, ~T[10:30:00]}},
              {{date, ~T[13:00:00]}, {date, ~T[14:00:00]}},
              {{date, ~T[20:30:00]}, {Date.add(date, 1), ~T[07:00:00]}}
            ]),
          do:
            sleep(
              date.day * 10 + n,
              1,
              DateTime.new!(elem(from, 0), elem(from, 1), "Etc/UTC"),
              DateTime.new!(elem(to, 0), elem(to, 1), "Etc/UTC")
            )

    [{child, imported}] = BacktestImport.parse(export([child(1, "Astrid")], entries))
    assert length(imported) == length(entries)

    assert %{points: points} = Backtest.run(child, imported, to: ~D[2026-03-24], days: 5)
    assert points > 0
  end
end
