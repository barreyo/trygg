defmodule Trygg.Reports.Backtest do
  @moduledoc """
  Replays a child's history to score `Trygg.Reports.Insights` predictions, so a
  change to the model is measured, not guessed.

  At every wake the app would have predicted from (the morning wake and the end
  of each nap) it rebuilds the same trailing window of days using only what
  was logged by then, makes the prediction, and compares it with what actually
  happened next. Overnight it does the same shortly after the night began, for
  the first feed and the morning wake.

  Scored kinds (`error = actual - predicted`, so positive means later than
  predicted):

    * `:next_nap` — the next sleep after a wake, within 8 hours (as the
      `Trygg.Reports.PredictionLedger` scores it)
    * `:bedtime` — that day's bedtime
    * `:first_feed` — the first waking of the night, from bedtime
    * `:morning_wake` — the wake that ends the night

  Each kind reports `%{n, mae_seconds, bias_seconds, median_abs_seconds,
  within_15_min, in_range}`; `in_range` is the share of misses that landed in
  the predicted range, `nil` when no prediction had one.

  Pure: takes the child and every entry (sleeps, feeds, diapers) to replay. It
  does not use the ledger's bias, accuracy or cue factor — those are feedback
  from the live app — so it scores the model itself.

  Compare variants with `compare/4`; `Insights.legacy_features/0` is the model
  before the refinements. `mix trygg.backtest` runs it against a stored child.
  """

  alias Trygg.Families.Child
  alias Trygg.Reports.Day
  alias Trygg.Reports.Insights

  # What `Trygg.Reports.PredictionLedger` rebuilds for each prediction.
  @window_days 16
  @lookback_seconds 36 * 3600
  @nap_horizon_seconds 8 * 3600
  @default_days 14
  @good_seconds 15 * 60

  @kinds [:next_nap, :bedtime, :first_feed, :morning_wake]

  @doc "The kinds that are scored."
  def kinds, do: @kinds

  @doc """
  Scores the model over the last `:days` (default #{@default_days}) local days.

  Options: `:days`, `:to` (last date scored; default the date of the latest
  finished sleep), `:features` (see `Insights.summarize/5`) and
  `:half_life_days`.
  """
  def run(%Child{} = child, entries, opts \\ []) when is_list(entries) do
    sleeps =
      entries
      |> Enum.filter(&(&1.type == :sleep))
      |> Enum.sort_by(& &1.started_at, DateTime)

    case last_finished(sleeps) do
      nil ->
        empty()

      latest ->
        to = opts[:to] || local_date(child, latest)
        from = Date.add(to, -((opts[:days] || @default_days) - 1))
        replay(child, entries, sleeps, from, to, opts)
    end
  end

  @doc """
  Runs `run/3` for each `{name, overrides}` variant, merging `overrides` over
  `opts`. Returns `[{name, result}]`.
  """
  def compare(%Child{} = child, entries, variants, opts \\ []) do
    Enum.map(variants, fn {name, overrides} ->
      {name, run(child, entries, Keyword.merge(opts, overrides))}
    end)
  end

  ## Replay -----------------------------------------------------------------

  defp replay(child, entries, sleeps, from, to, opts) do
    final_now = DateTime.add(latest_activity(entries), 3600, :second)

    truth =
      Map.new(Date.range(Date.add(from, -1), Date.add(to, 1)), fn date ->
        {date, Day.build(child, date, entries, final_now)}
      end)

    points =
      for date <- Date.range(from, to),
          point <- wake_points(truth, date) ++ night_points(child, truth, date),
          do: point

    summarize_opts =
      [features: opts[:features], half_life_days: opts[:half_life_days]]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    scored =
      Enum.flat_map(points, fn point ->
        score(child, entries, sleeps, truth, point, summarize_opts)
      end)

    %{points: length(points), kinds: aggregate(scored)}
  end

  # Moments the app would predict "next nap" and "bedtime" from.
  defp wake_points(truth, date) do
    day = Map.fetch!(truth, date)

    morning =
      if day.morning_wake, do: [%{type: :wake, at: day.morning_wake, date: date}], else: []

    naps =
      for nap <- day.naps, not nap.running?, do: %{type: :wake, at: nap.end, date: date}

    morning ++ naps
  end

  # Shortly after the night began (once it counts as a night, not a nap).
  defp night_points(child, truth, date) do
    day = Map.fetch!(truth, date)

    case day.bedtime do
      %DateTime{} = bed ->
        {night_start, _} = Child.night_bounds(child, date)
        at = bed |> latest(night_start) |> DateTime.add(60, :second)
        [%{type: :night, at: at, bed: bed, date: date}]

      nil ->
        []
    end
  end

  defp score(child, entries, sleeps, truth, point, summarize_opts) do
    now = if point.type == :wake, do: DateTime.add(point.at, 60, :second), else: point.at
    today = local_date(child, now)
    window_from = Date.add(today, -(@window_days - 1))
    visible = visible_entries(child, entries, now, window_from)

    days =
      for date <- Date.range(Date.add(today, -(@window_days - 1)), today),
          do: Day.build(child, date, visible, now)

    prediction = Insights.summarize(child, days, List.last(days), now, summarize_opts).prediction

    case point.type do
      :wake -> score_wake(prediction, sleeps, truth, point)
      :night -> score_night(prediction, truth, point)
    end
  end

  defp score_wake(%{state: :awake} = prediction, sleeps, truth, %{at: wake, date: date}) do
    next_nap =
      with %{at: at} = nap <- prediction.next_nap,
           %DateTime{} = actual <- first_sleep_after(sleeps, wake) do
        [error(:next_nap, at, actual, nap[:range])]
      else
        _ -> []
      end

    bedtime =
      with %{at: at} = bed <- prediction.bedtime,
           %DateTime{} = actual <- Map.fetch!(truth, date).bedtime,
           :gt <- DateTime.compare(actual, wake) do
        [error(:bedtime, at, actual, bed[:range])]
      else
        _ -> []
      end

    next_nap ++ bedtime
  end

  defp score_wake(_prediction, _sleeps, _truth, _point), do: []

  defp score_night(%{state: :asleep, night: %{} = night}, truth, %{at: at, date: date}) do
    day = Map.fetch!(truth, date)

    first_feed =
      with %{} = feed <- night.next_feed,
           [%{start: actual} | _] <- day.night_wakings,
           :gt <- DateTime.compare(actual, at) do
        [error(:first_feed, feed.at, actual, feed[:range])]
      else
        _ -> []
      end

    morning =
      with %{at: predicted} = morning <- night.morning_wake,
           %DateTime{} = actual <- Map.fetch!(truth, Date.add(date, 1)).morning_wake do
        [error(:morning_wake, predicted, actual, morning[:range])]
      else
        _ -> []
      end

    first_feed ++ morning
  end

  defp score_night(_prediction, _truth, _point), do: []

  defp error(kind, predicted, actual, range) do
    %{
      kind: kind,
      error: DateTime.diff(actual, predicted, :second),
      in_range: in_range(range, actual)
    }
  end

  defp in_range(%{from: from, to: to}, actual) do
    DateTime.compare(actual, from) != :lt and DateTime.compare(actual, to) != :gt
  end

  defp in_range(_range, _actual), do: nil

  # What had been logged by `now`: later entries are gone, and a sleep still
  # going at `now` is running.
  defp visible_entries(child, entries, now, window_from) do
    {window_start, _} = Child.day_bounds(child, window_from)
    since = DateTime.add(window_start, -@lookback_seconds, :second)

    for entry <- entries,
        DateTime.compare(entry.started_at, now) != :gt,
        DateTime.compare(entry.started_at, since) != :lt do
      if (entry.type == :sleep and entry.ended_at) && DateTime.compare(entry.ended_at, now) == :gt,
        do: %{entry | ended_at: nil},
        else: entry
    end
  end

  defp first_sleep_after(sleeps, wake) do
    case Enum.find(sleeps, &(DateTime.compare(&1.started_at, wake) == :gt)) do
      %{started_at: started} ->
        if DateTime.diff(started, wake, :second) <= @nap_horizon_seconds, do: started

      nil ->
        nil
    end
  end

  ## Aggregation --------------------------------------------------------------

  defp aggregate(scored) do
    grouped = Enum.group_by(scored, & &1.kind)
    Map.new(@kinds, fn kind -> {kind, summary(Map.get(grouped, kind, []))} end)
  end

  defp summary([]) do
    %{
      n: 0,
      mae_seconds: nil,
      bias_seconds: nil,
      median_abs_seconds: nil,
      within_15_min: nil,
      in_range: nil
    }
  end

  defp summary(rows) do
    errors = Enum.map(rows, & &1.error)
    abs_errors = Enum.map(errors, &abs/1)
    n = length(rows)
    ranged = Enum.reject(rows, &is_nil(&1.in_range))

    %{
      n: n,
      mae_seconds: round(Enum.sum(abs_errors) / n),
      bias_seconds: round(Enum.sum(errors) / n),
      median_abs_seconds: median(abs_errors),
      within_15_min: Enum.count(abs_errors, &(&1 <= @good_seconds)) / n,
      in_range:
        if(ranged == [], do: nil, else: Enum.count(ranged, & &1.in_range) / length(ranged))
    }
  end

  defp median(values) do
    sorted = Enum.sort(values)
    mid = div(length(sorted), 2)

    if rem(length(sorted), 2) == 1,
      do: Enum.at(sorted, mid),
      else: round((Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2)
  end

  ## Helpers ------------------------------------------------------------------

  defp empty, do: %{points: 0, kinds: aggregate([])}

  defp last_finished(sleeps) do
    sleeps
    |> Enum.map(& &1.ended_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp latest_activity(entries) do
    entries
    |> Enum.flat_map(&[&1.started_at, &1.ended_at])
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime)
  end

  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  defp local_date(%Child{timezone: tz}, %DateTime{} = dt) do
    dt |> DateTime.shift_zone!(tz) |> DateTime.to_date()
  end
end
