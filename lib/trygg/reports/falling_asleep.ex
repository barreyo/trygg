defmodule Trygg.Reports.FallingAsleep do
  @moduledoc """
  How the child's way of falling asleep changes over the weeks: the average
  level on the sliding scale of intervention (`Trygg.Sleep.Assist`, 1 = fed or
  rocked to sleep … 9 = fell asleep alone), the typical time to settle, and the
  share of sleeps at level 8–9.

  Pure: takes the child, their sleep entries and today's local date.
  """

  alias Trygg.Families.Child
  alias Trygg.Reports.Stats

  @weeks 6
  @independent_from 8

  @doc "How many weeks `summarize/3` looks back."
  def weeks, do: @weeks

  @doc """
  `%{weeks, this_week, previous, trend, tracked, latest}`.

  `weeks` has one entry per week, oldest first, the last ending today:
  `%{from, to, n, mean_level, median_settle, independent_share}` (`mean_level`,
  `median_settle` and `independent_share` are `nil` for a week with no tracked
  sleeps). `previous` is the latest earlier week with data, `trend` the change
  in mean level against it, `tracked` the number of sleeps with a level in the
  window and `latest` the level of the most recent one.
  """
  def summarize(%Child{} = child, entries, %Date{} = today) when is_list(entries) do
    tracked =
      for %{type: :sleep, data: %{"assist" => level}} = e <- entries, is_integer(level) do
        {local_date(child, e.started_at), e}
      end

    weeks =
      for i <- (@weeks - 1)..0//-1 do
        to = Date.add(today, -i * 7)
        from = Date.add(to, -6)
        week(from, to, Enum.filter(tracked, fn {d, _} -> in_range?(d, from, to) end))
      end

    this_week = List.last(weeks)
    previous = weeks |> Enum.drop(-1) |> Enum.reverse() |> Enum.find(&(&1.n > 0))

    %{
      weeks: weeks,
      this_week: this_week,
      previous: previous,
      trend: trend(this_week, previous),
      tracked: Enum.sum(Enum.map(weeks, & &1.n)),
      latest: latest(tracked)
    }
  end

  defp week(from, to, tracked) do
    levels = for {_, e} <- tracked, do: e.data["assist"]

    settles =
      for {_, e} <- tracked, is_integer(e.data["settle_minutes"]), do: e.data["settle_minutes"]

    n = length(levels)

    %{
      from: from,
      to: to,
      n: n,
      mean_level: if(n > 0, do: Enum.sum(levels) / n),
      median_settle: if(settles != [], do: round(Stats.median(settles))),
      independent_share: if(n > 0, do: Enum.count(levels, &(&1 >= @independent_from)) / n)
    }
  end

  defp trend(%{mean_level: now}, %{mean_level: before}) when is_number(now) and is_number(before),
    do: now - before

  defp trend(_this, _previous), do: nil

  defp latest([]), do: nil

  defp latest(tracked) do
    {_, e} = Enum.max_by(tracked, fn {_, e} -> DateTime.to_unix(e.started_at) end)
    e.data["assist"]
  end

  defp in_range?(date, from, to),
    do: Date.compare(date, from) != :lt and Date.compare(date, to) != :gt

  defp local_date(child, at),
    do: at |> DateTime.shift_zone!(child.timezone) |> DateTime.to_date()
end
