defmodule Trygg.ReportDays do
  @moduledoc """
  Synthetic `%Trygg.Log.Entry{}` structs and `%Trygg.Reports.Day{}` builders
  for the pure report modules. Everything is in `Etc/UTC` with an 08:00 day
  start and a 20:00 night start so clock arithmetic in tests is trivial.
  """

  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias Trygg.Reports.Day

  def child(attrs \\ %{}) do
    struct!(
      %Child{
        timezone: "Etc/UTC",
        day_start: ~T[08:00:00],
        night_start: ~T[20:00:00]
      },
      attrs
    )
  end

  def at(%Date{} = date, %Time{} = time), do: DateTime.new!(date, time, "Etc/UTC")

  def feed(id, %DateTime{} = at, ml \\ 90) do
    %Entry{id: id, type: :feeding, started_at: at, ended_at: at, data: %{"amount_ml" => ml}}
  end

  def diaper(id, %DateTime{} = at, kind \\ "pee") do
    %Entry{id: id, type: :diaper, started_at: at, ended_at: at, data: %{"kind" => kind}}
  end

  def sleep(id, %DateTime{} = start, finish) do
    %Entry{id: id, type: :sleep, started_at: start, ended_at: finish, data: %{}}
  end

  @doc """
  Builds `%Day{}`s for every date in `dates` from one flat list of entries.
  """
  def build_days(child, dates, entries, now) do
    Enum.map(dates, &Day.build(child, &1, entries, now))
  end

  @doc "Consecutive dates ending on `last`, `n` of them, oldest first."
  def dates_ending(%Date{} = last, n), do: Enum.map((n - 1)..0//-1, &Date.add(last, -&1))

  @doc """
  A regular feeding day: bottles every `every` hours from `first` (a `Time`),
  `count` of them, `ml` each. Returns entries with ids derived from the date.
  """
  def feed_day(%Date{} = date, opts \\ []) do
    first = Keyword.get(opts, :first, ~T[06:00:00])
    every = Keyword.get(opts, :every_hours, 3)
    count = Keyword.get(opts, :count, 6)
    ml = Keyword.get(opts, :ml, 90)
    base = Keyword.get(opts, :id_base, date.day * 1000)

    for i <- 0..(count - 1) do
      feed(base + i, at(date, first) |> DateTime.add(i * every * 3600, :second), ml)
    end
  end

  @doc "`count` wet diapers spread across the day from `first`."
  def diaper_day(%Date{} = date, opts \\ []) do
    first = Keyword.get(opts, :first, ~T[07:00:00])
    every = Keyword.get(opts, :every_hours, 2)
    count = Keyword.get(opts, :count, 7)
    kind = Keyword.get(opts, :kind, "pee")
    base = Keyword.get(opts, :id_base, date.day * 1000 + 500)

    for i <- 0..(count - 1) do
      diaper(base + i, at(date, first) |> DateTime.add(i * every * 3600, :second), kind)
    end
  end

  @default_naps [{~T[10:00:00], ~T[11:00:00]}, {~T[14:00:00], ~T[15:00:00]}]

  @doc """
  Regular sleep across consecutive `dates`: a night stretch before the first
  date, then per date the naps and a night from `bed` to the next morning's
  `wake`. `opts_fun.(date)` may return `wake:`, `bed:`, `naps:` overrides so
  individual days can differ.
  """
  def sleep_days(dates, opts_fun \\ fn _date -> [] end) do
    first = hd(dates)
    first_opts = opts_fun.(first)

    lead_in = [
      sleep(
        1,
        at(Date.add(first, -1), ~T[20:00:00]),
        at(first, Keyword.get(first_opts, :wake, ~T[07:00:00]))
      )
    ]

    per_day =
      dates
      |> Enum.with_index()
      |> Enum.flat_map(fn {date, i} ->
        opts = opts_fun.(date)
        base = 100 + i * 100
        naps = Keyword.get(opts, :naps, @default_naps)
        bed = Keyword.get(opts, :bed, ~T[20:00:00])
        next = Date.add(date, 1)
        next_wake = Keyword.get(opts_fun.(next), :wake, ~T[07:00:00])

        nap_entries =
          naps
          |> Enum.with_index(1)
          |> Enum.map(fn {{s, f}, j} -> sleep(base + j, at(date, s), at(date, f)) end)

        nap_entries ++ [sleep(base + 50, at(date, bed), at(next, next_wake))]
      end)

    lead_in ++ per_day
  end
end
