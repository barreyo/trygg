defmodule Trygg.Reports.PredictionLedger do
  @moduledoc """
  Records the sleep predictions the app makes and, once the child next falls
  asleep, how far off each one was.

  This is instrumentation, not behaviour: `track/2` recomputes the same
  `Trygg.Reports.Insights` prediction the Home screen shows, writes an open
  `Trygg.Reports.Prediction` row per wake (`:next_nap`, `:bedtime`), and closes
  out any earlier rows whose predicted sleep has now happened — with a signed
  `error_seconds` (actual minus target). Rows whose predicted sleep never comes
  are resolved with a `nil` error after a per-kind horizon.

  `accuracy/3` reads the recent resolved rows back as a recency-weighted mean
  absolute error and bias, for later phases to widen the shown range and
  de-bias the point estimate.

  `Trygg.Reports.PredictionWorker` calls `track/2` (per child) and `sweep/1`
  (all recently-active children) from Oban; both are pure enough to call
  directly from IEx or tests.
  """
  import Ecto.Query

  require Logger

  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias Trygg.Reports.Day
  alias Trygg.Reports.Insights
  alias Trygg.Reports.Prediction
  alias Trygg.Repo

  # Days of history to rebuild so the recomputed prediction matches what the
  # dashboard's 14-day outlook window produced.
  @window_days 16
  @lookback_hours 36

  # How long after the keyed-off wake we keep waiting for the predicted sleep
  # before giving up on the row (resolved, but no error recorded).
  @nap_horizon_seconds 8 * 3600
  @bedtime_horizon_seconds 24 * 3600

  # Children with a sleep logged in this window are re-checked by `sweep/1`.
  @sweep_lookback_seconds 2 * 24 * 3600

  @doc """
  Records the current open predictions for `child` and reconciles any matured
  ones. `child` may be a `%Child{}` or a child id.
  """
  def track(child, now \\ DateTime.utc_now())

  def track(%Child{} = child, now) do
    now = DateTime.truncate(now, :second)
    {days, today_day, sleeps} = context(child, now)

    prediction =
      Insights.summarize(child, days, today_day, now, prediction_opts(child.id)).prediction

    record_open(child, prediction, now)
    reconcile(child, sleeps, days, now)
    :ok
  end

  def track(child_id, now) when is_integer(child_id) do
    case Repo.get(Child, child_id) do
      %Child{} = child -> track(child, now)
      nil -> :ok
    end
  end

  @doc """
  The `Trygg.Reports.Insights` prediction for `child` at `now`, built from the
  same context `track/2` uses but without recording anything. `child` may be a
  `%Child{}` or a child id (`nil` for an unknown id).
  """
  def prediction(child, now \\ DateTime.utc_now())

  def prediction(%Child{} = child, now) do
    now = DateTime.truncate(now, :second)
    {days, today_day, _sleeps} = context(child, now)
    Insights.summarize(child, days, today_day, now, prediction_opts(child.id)).prediction
  end

  def prediction(child_id, now) when is_integer(child_id) do
    case Repo.get(Child, child_id) do
      %Child{} = child -> prediction(child, now)
      nil -> nil
    end
  end

  @doc """
  Runs `track/2` for every child with a sleep entry in the last two days.
  Returns the number of children checked.
  """
  def sweep(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)
    since = DateTime.add(now, -@sweep_lookback_seconds, :second)

    child_ids =
      Entry
      |> where([e], e.type == :sleep and e.started_at >= ^since)
      |> select([e], e.child_id)
      |> distinct(true)
      |> Repo.all()

    Enum.each(child_ids, &track(&1, now))
    length(child_ids)
  end

  @doc """
  Recency-weighted accuracy of recent resolved predictions for a child and
  kind, or `nil` when nothing has resolved yet.

  Returns `%{n, mae_seconds, bias_seconds, recent}` — `bias_seconds` is signed
  (positive = the child sleeps later than predicted); `recent` is the last few
  signed errors, newest first.
  """
  def accuracy(child_id, kind, opts \\ []) when kind in [:next_nap, :bedtime] do
    limit = Keyword.get(opts, :limit, 30)
    half_life = Keyword.get(opts, :half_life, 5)

    rows =
      Prediction
      |> where([p], p.child_id == ^child_id and p.kind == ^kind and not is_nil(p.error_seconds))
      |> order_by([p], desc: p.resolved_at)
      |> limit(^limit)
      |> Repo.all()

    case rows do
      [] ->
        nil

      rows ->
        weighted =
          rows
          |> Enum.with_index()
          |> Enum.map(fn {row, i} -> {row, :math.pow(0.5, i / half_life)} end)

        wsum = weighted |> Enum.map(&elem(&1, 1)) |> Enum.sum()
        mae = Enum.sum(Enum.map(weighted, fn {r, w} -> w * abs(r.error_seconds) end)) / wsum
        bias = Enum.sum(Enum.map(weighted, fn {r, w} -> w * r.error_seconds end)) / wsum

        %{
          n: length(rows),
          mae_seconds: round(mae),
          bias_seconds: round(bias),
          recent: Enum.map(rows, & &1.error_seconds)
        }
    end
  end

  @doc """
  Feedback for `Trygg.Reports.Insights.summarize/5`: a recency half-life
  override when the recent errors look like a regime shift, and a per-kind
  signed bias to correct out.
  """
  def prediction_opts(child_id) do
    nap = accuracy(child_id, :next_nap)
    bed = accuracy(child_id, :bedtime)

    half_life =
      if regime_shift?(nap) or regime_shift?(bed) do
        max(div(Insights.recency_half_life_days(), 2), 1)
      end

    [
      half_life_days: half_life,
      bias: %{next_nap: bias_for(nap), bedtime: bias_for(bed)}
    ]
  end

  # Enough resolved rows, and the last few errors all lean the same way and are
  # each more than ~25 min off — the schedule has moved under the model.
  defp regime_shift?(%{recent: recent}) when length(recent) >= 5 do
    last = Enum.take(recent, 5)
    Enum.all?(last, &(&1 > 25 * 60)) or Enum.all?(last, &(&1 < -25 * 60))
  end

  defp regime_shift?(_accuracy), do: false

  defp bias_for(%{bias_seconds: b, n: n}) when n >= 4, do: b
  defp bias_for(_accuracy), do: 0

  ## Recording ----------------------------------------------------------

  defp record_open(
         %Child{id: child_id},
         %{state: :awake, anchor_ts: %DateTime{} = anchor} = pred,
         now
       ) do
    from = DateTime.truncate(anchor, :second)

    if nap = pred.next_nap do
      upsert(
        child_id,
        :next_nap,
        %{
          made_from_ts: from,
          ordinal: nap.ordinal,
          source: nap.source,
          target_ts: DateTime.truncate(nap.at, :second),
          range_lo_ts: nap.range && DateTime.truncate(nap.range.from, :second),
          range_hi_ts: nap.range && DateTime.truncate(nap.range.to, :second)
        },
        now
      )
    end

    if bed = pred.bedtime do
      upsert(
        child_id,
        :bedtime,
        %{
          made_from_ts: from,
          ordinal: nil,
          source: Map.get(bed, :source, :blended),
          target_ts: DateTime.truncate(bed.at, :second),
          range_lo_ts: nil,
          range_hi_ts: nil
        },
        now
      )
    end
  end

  defp record_open(_child, _prediction, _now), do: :ok

  # One open row per {child, kind, wake}. A re-run refines an unresolved row;
  # it never reopens one that already resolved.
  defp upsert(child_id, kind, attrs, now) do
    case Repo.get_by(Prediction, child_id: child_id, kind: kind, made_from_ts: attrs.made_from_ts) do
      nil ->
        %Prediction{child_id: child_id, kind: kind}
        |> Prediction.changeset(Map.put(attrs, :made_at, now))
        |> Repo.insert()

      %Prediction{resolved_at: nil} = row ->
        row
        |> Prediction.changeset(Map.put(attrs, :made_at, now))
        |> Repo.update()

      %Prediction{} = resolved ->
        {:ok, resolved}
    end
  rescue
    error ->
      Logger.warning("prediction upsert failed for child #{child_id}: #{inspect(error)}")
      :error
  end

  ## Reconciliation ---------------------------------------------------------

  defp reconcile(%Child{id: child_id}, sleeps, days, now) do
    Prediction
    |> where([p], p.child_id == ^child_id and is_nil(p.resolved_at))
    |> Repo.all()
    |> Enum.each(fn prediction ->
      case actual_onset(prediction, sleeps, days) do
        %DateTime{} = actual ->
          resolve(prediction, actual, now)

        nil ->
          if DateTime.diff(now, prediction.made_from_ts, :second) > horizon(prediction.kind) do
            abandon(prediction, now)
          end
      end
    end)
  end

  # The first real sleep onset strictly after the wake this row keyed off,
  # within the kind's horizon.
  defp actual_onset(%Prediction{kind: :next_nap, made_from_ts: from}, sleeps, _days) do
    sleeps
    |> Enum.map(& &1.started_at)
    |> earliest_after(from)
    |> within_horizon(from, @nap_horizon_seconds)
  end

  defp actual_onset(%Prediction{kind: :bedtime, made_from_ts: from}, _sleeps, days) do
    days
    |> Enum.map(& &1.bedtime)
    |> Enum.reject(&is_nil/1)
    |> earliest_after(from)
    |> within_horizon(from, @bedtime_horizon_seconds)
  end

  defp earliest_after(times, from) do
    times
    |> Enum.filter(&(DateTime.compare(&1, from) == :gt))
    |> Enum.min_by(&DateTime.to_unix/1, fn -> nil end)
  end

  defp within_horizon(nil, _from, _max), do: nil

  defp within_horizon(%DateTime{} = dt, from, max) do
    if DateTime.diff(dt, from, :second) <= max, do: dt, else: nil
  end

  defp horizon(:next_nap), do: @nap_horizon_seconds
  defp horizon(:bedtime), do: @bedtime_horizon_seconds

  defp resolve(%Prediction{} = prediction, %DateTime{} = actual, now) do
    prediction
    |> Prediction.changeset(%{
      actual_ts: actual,
      error_seconds: DateTime.diff(actual, prediction.target_ts, :second),
      resolved_at: now
    })
    |> Repo.update()
  end

  defp abandon(%Prediction{} = prediction, now) do
    prediction
    |> Prediction.changeset(%{resolved_at: now})
    |> Repo.update()
  end

  ## Context --------------------------------------------------------------

  defp context(%Child{} = child, now) do
    today = local_date(child, now)
    from_date = Date.add(today, -(@window_days - 1))
    {day_start, _} = Child.day_bounds(child, from_date)
    since = DateTime.add(day_start, -@lookback_hours * 3600, :second)

    sleeps =
      Entry
      |> where([e], e.child_id == ^child.id and e.type == :sleep and e.started_at >= ^since)
      |> order_by([e], asc: e.started_at)
      |> Repo.all()

    days =
      from_date
      |> Date.range(today)
      |> Enum.map(&Day.build(child, &1, sleeps, now))

    {days, List.last(days), sleeps}
  end

  defp local_date(%Child{timezone: tz}, now) do
    now |> DateTime.shift_zone!(tz) |> DateTime.to_date()
  end
end
