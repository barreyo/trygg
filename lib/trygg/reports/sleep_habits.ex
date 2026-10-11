defmodule Trygg.Reports.SleepHabits do
  @moduledoc """
  Newborn sleep habits worth seeing at a glance, derived from the log:

    * **Cues** — how many sleeps had a sleepy cue noted (`data["cue"]`, see
      `Trygg.Sleep.Cue`), how many started overtired, and how long they had been
      awake before sleeps noted as tired / ready / overtired.
    * **Feed → sleep** — how many sleeps began within 10 minutes of a feed
      (a bottle, or a breastfeeding session that was still going). The guides
      suggest practising feed → awake time → sleep when it's easy, but are clear
      that feeding to sleep is fine too; this is a pattern to see, not a score.

  Pure: takes a child, entries (sleeps, bottles and breastfeeding, covering the
  window plus 6 hours before it), today's date and `now`.
  """

  alias Trygg.Families.Child
  alias Trygg.Reports.Stats
  alias Trygg.Sleep.Cue

  @window_days 7
  @fed_to_sleep_seconds 10 * 60
  # How far back to look for the feed before a sleep.
  @feed_lookback_seconds 6 * 3600
  # Awake stretches longer than this are a night or a gap in the log, not a wake window.
  @max_awake_seconds 4 * 3600
  @min_cue_sample 3

  # Cue-based adjustment of wake-window predictions (see `cue_adjustment/3`).
  @cue_adjust_days 14
  @min_ready_samples 4
  @min_awake_samples 8
  @cue_shrink_k 6
  @min_cue_factor 0.85
  @max_cue_factor 1.15

  @doc "Days the weekly figures cover, ending today."
  def window_days, do: @window_days

  @doc "How far before the window start the caller must fetch entries, in seconds."
  def lookback_seconds, do: @feed_lookback_seconds

  @doc "Feed-to-sleep gap, in seconds, at or under which a sleep counts as fed-to-sleep."
  def fed_to_sleep_seconds, do: @fed_to_sleep_seconds

  @doc """
  Returns `%{today: stats, week: stats, cue_windows: %{cue_id => %{n, median_seconds}}}`
  where `stats` is `%{sleeps, cued, overtired, measured, fed_to_sleep}`:
  `measured` is the sleeps with a feed in the six hours before them.
  `cue_windows` has only the cues with at least 3 sleeps in the window.
  """
  def summarize(%Child{} = child, entries, %Date{} = today, %DateTime{} = now)
      when is_list(entries) do
    sleeps =
      entries
      |> Enum.filter(&(&1.type == :sleep))
      |> Enum.sort_by(& &1.started_at, DateTime)

    feeds = Enum.filter(entries, &(&1.type in [:feeding, :breastfeeding]))

    from = Date.add(today, 1 - @window_days)

    week =
      [nil | sleeps]
      |> Enum.zip(sleeps)
      |> Enum.map(fn {previous, sleep} -> annotate(child, sleep, previous, feeds, now) end)
      |> Enum.filter(
        &(Date.compare(&1.date, from) != :lt and Date.compare(&1.date, today) != :gt)
      )

    %{
      today: stats(Enum.filter(week, &(&1.date == today))),
      week: stats(week),
      cue_windows: cue_windows(week)
    }
  end

  @doc """
  How the child's "ready" cues compare with their actual wake windows over the
  last 14 days, as a factor to nudge predicted wake windows by.

  Sleeps are started when a parent decides to, which may be early or late
  relative to the cues. If sleeps noted as *ready* come after a shorter stretch
  awake than sleeps in general, the true sweet spot is earlier than the history
  suggests, and the factor is below 1 (above 1 if it's later). The ratio is
  shrunk toward 1 by sample size and bounded to 0.85–1.15.

  Returns `nil` until there are 4 ready sleeps and 8 sleeps with a known
  wake window; otherwise `%{factor, ready_seconds, overall_seconds, n_ready, n_overall}`.
  """
  def cue_adjustment(%Child{} = child, entries, %Date{} = today) when is_list(entries) do
    from = Date.add(today, 1 - @cue_adjust_days)

    sleeps =
      entries
      |> Enum.filter(&(&1.type == :sleep))
      |> Enum.sort_by(& &1.started_at, DateTime)

    samples =
      [nil | sleeps]
      |> Enum.zip(sleeps)
      |> Enum.flat_map(fn {previous, sleep} ->
        date = local_date(child, sleep.started_at)

        with true <- Date.compare(date, from) != :lt and Date.compare(date, today) != :gt,
             awake when is_integer(awake) <- awake_before(sleep, previous) do
          [{sleep.data["cue"], awake}]
        else
          _ -> []
        end
      end)

    ready = for {"ready", awake} <- samples, do: awake
    overall = Enum.map(samples, &elem(&1, 1))

    if length(ready) >= @min_ready_samples and length(overall) >= @min_awake_samples do
      ready_median = Stats.median(ready)
      overall_median = Stats.median(overall)
      ratio = if overall_median > 0, do: ready_median / overall_median, else: 1.0
      w = length(ready) / (length(ready) + @cue_shrink_k)

      %{
        factor: (1 + (ratio - 1) * w) |> max(@min_cue_factor) |> min(@max_cue_factor),
        ready_seconds: round(ready_median),
        overall_seconds: round(overall_median),
        n_ready: length(ready),
        n_overall: length(overall)
      }
    end
  end

  defp local_date(child, at),
    do: at |> DateTime.shift_zone!(child.timezone) |> DateTime.to_date()

  defp annotate(child, sleep, previous, feeds, now) do
    %{
      date: local_date(child, sleep.started_at),
      cue: sleep.data["cue"],
      feed_gap: feed_gap(sleep, feeds, now),
      awake_before: awake_before(sleep, previous)
    }
  end

  # Seconds between the end of the closest feed that started at or before the
  # sleep and the sleep's start; 0 when the feed was still going.
  defp feed_gap(sleep, feeds, now) do
    earliest = DateTime.add(sleep.started_at, -@feed_lookback_seconds, :second)

    feeds
    |> Enum.filter(fn feed ->
      DateTime.compare(feed.started_at, sleep.started_at) != :gt and
        DateTime.compare(feed.started_at, earliest) != :lt
    end)
    |> Enum.map(fn feed ->
      max(DateTime.diff(sleep.started_at, feed_end(feed, now), :second), 0)
    end)
    |> Enum.min(fn -> nil end)
  end

  defp feed_end(%{ended_at: nil}, now), do: now
  defp feed_end(%{ended_at: ended}, _now), do: ended

  defp awake_before(_sleep, nil), do: nil
  defp awake_before(_sleep, %{ended_at: nil}), do: nil

  defp awake_before(sleep, previous) do
    awake = DateTime.diff(sleep.started_at, previous.ended_at, :second)
    if awake >= 0 and awake <= @max_awake_seconds, do: awake
  end

  defp stats(annotated) do
    %{
      sleeps: length(annotated),
      cued: Enum.count(annotated, & &1.cue),
      overtired: Enum.count(annotated, &(&1.cue == "overtired")),
      measured: Enum.count(annotated, & &1.feed_gap),
      fed_to_sleep: Enum.count(annotated, &(&1.feed_gap && &1.feed_gap <= @fed_to_sleep_seconds))
    }
  end

  defp cue_windows(annotated) do
    for id <- Cue.ids(),
        awake = for(a <- annotated, a.cue == id and a.awake_before, do: a.awake_before),
        length(awake) >= @min_cue_sample,
        into: %{} do
      {id, %{n: length(awake), median_seconds: round(Stats.median(awake))}}
    end
  end
end
