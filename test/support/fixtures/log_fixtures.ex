defmodule Trygg.LogFixtures do
  @moduledoc "Test helpers for creating log entries."

  alias Trygg.Families.Child
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

  @doc """
  Lays down `days` days of bottles, one every `:every_hours` (3), the most
  recent `:last_hours_ago` (1) hours before `:now` (current time), `:ml` (90)
  each. Returns the entries.
  """
  def feed_days(scope, child, days, opts \\ []) do
    every = Keyword.get(opts, :every_hours, 3)
    ml = Keyword.get(opts, :ml, 90)
    last = hours_ago(Keyword.get(opts, :last_hours_ago, 1), Keyword.get(opts, :now))
    count = div(days * 24, every)

    for i <- (count - 1)..0//-1 do
      entry_fixture(scope, child, %{
        :type => :feeding,
        "started_at" => DateTime.add(last, -i * every * 3600, :second),
        "data" => %{"bottle_contents" => "formula", "amount_ml" => ml}
      })
    end
  end

  @doc """
  Lays down `days` days of diapers of `:kind` ("pee"), one every `:every_hours`
  (3), the most recent `:last_hours_ago` (1) hours before `:now` (current
  time). Returns the entries.
  """
  def diaper_days(scope, child, days, opts \\ []) do
    every = Keyword.get(opts, :every_hours, 3)
    kind = Keyword.get(opts, :kind, "pee")
    last = hours_ago(Keyword.get(opts, :last_hours_ago, 1), Keyword.get(opts, :now))
    count = div(days * 24, every)

    for i <- (count - 1)..0//-1 do
      entry_fixture(scope, child, %{
        :type => :diaper,
        "started_at" => DateTime.add(last, -i * every * 3600, :second),
        "data" => %{"kind" => kind}
      })
    end
  end

  @doc """
  Lays down a regular sleep pattern for the `days` local days before today:
  a night from `:bed` (20:00) to `:wake` (07:00) and naps at `:naps`
  (`[{10:00, 11:00}, {14:00, 15:00}]`), plus last night's stretch ending this
  morning. Anything that would end in the future is skipped.
  """
  def sleep_days(scope, child, days, opts \\ []) do
    bed = Keyword.get(opts, :bed, ~T[20:00:00])
    wake = Keyword.get(opts, :wake, ~T[07:00:00])
    naps = Keyword.get(opts, :naps, [{~T[10:00:00], ~T[11:00:00]}, {~T[14:00:00], ~T[15:00:00]}])
    today = Child.local_today(child)
    now = DateTime.utc_now()

    dates = for i <- days..1//-1, do: Date.add(today, -i)

    stretches =
      Enum.flat_map(dates, fn date ->
        nap_stretches =
          Enum.map(naps, fn {s, f} ->
            {Child.at_local(child, date, s), Child.at_local(child, date, f)}
          end)

        night = {Child.at_local(child, date, bed), Child.at_local(child, Date.add(date, 1), wake)}
        nap_stretches ++ [night]
      end)

    lead_in =
      case dates do
        [first | _] ->
          [{Child.at_local(child, Date.add(first, -1), bed), Child.at_local(child, first, wake)}]

        [] ->
          []
      end

    (lead_in ++ stretches)
    |> Enum.filter(fn {_s, f} -> DateTime.compare(f, now) == :lt end)
    |> Enum.map(fn {s, f} ->
      entry_fixture(scope, child, %{:type => :sleep, "started_at" => s, "ended_at" => f})
    end)
  end

  @doc """
  A fixed-offset IANA zone in which the local hour is currently about 12, so
  "an hour ago" is unambiguously this afternoon whatever the wall clock says.
  """
  def midday_timezone do
    shift = 12 - DateTime.utc_now().hour

    cond do
      shift == 0 -> "Etc/UTC"
      # Etc/GMT-3 is UTC+3 (POSIX sign convention).
      shift > 0 -> "Etc/GMT-#{shift}"
      true -> "Etc/GMT+#{-shift}"
    end
  end

  @doc "A minimal but valid 1×1 PNG, for exercising photo uploads/storage."
  def tiny_png do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )
  end

  defp hours_ago(hours, now \\ nil) do
    (now || DateTime.utc_now())
    |> DateTime.truncate(:second)
    |> DateTime.add(-round(hours * 3600), :second)
  end

  defp default_data(:feeding), do: %{"bottle_contents" => "formula", "amount_ml" => 90}
  defp default_data(:diaper), do: %{"kind" => "pee"}
  defp default_data(:sleep), do: %{"location" => "bassinet"}
  defp default_data(_), do: %{}
end
