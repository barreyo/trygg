defmodule Trygg.Reports.FeedTiming do
  @moduledoc """
  Infers how long a feed took. Feeds are logged when the bottle is finished,
  so the gap from a diaper change to the feed that directly follows it (no
  other feed in between, so a top-up bottle is never timed from the same
  change) is taken as the feeding time.

  Pure: works on any maps with `:id` and `:at`, so both `%Day{}` markers and
  raw entries can be timed.
  """

  # A diaper logged closer to the feed than this was probably logged after the
  # fact alongside it, so the gap says nothing about how long the feed took.
  @min_feed_duration 3 * 60
  # Longer gaps are the change and feed being unrelated, not a long feed.
  @max_feed_duration 60 * 60

  @doc "Feed id => inferred feeding seconds, for the feeds that can be timed."
  def durations(feeds, diapers) do
    (Enum.map(feeds, &{:feed, &1}) ++ Enum.map(diapers, &{:diaper, &1}))
    |> Enum.sort_by(fn {_kind, marker} -> marker.at end, DateTime)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [{:diaper, diaper}, {:feed, feed}] ->
        seconds = DateTime.diff(feed.at, diaper.at, :second)

        if seconds >= @min_feed_duration and seconds <= @max_feed_duration,
          do: [{feed.id, seconds}],
          else: []

      _ ->
        []
    end)
    |> Map.new()
  end
end
