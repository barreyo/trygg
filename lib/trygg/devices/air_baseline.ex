defmodule Trygg.Devices.AirBaseline do
  @moduledoc """
  Whether a room's air is clearly worse than it usually is.

  The raw gas resistance of the sensor means little on its own (it also moves with
  humidity and with the age of the sensor), but against the same room's own history
  it does: a sustained drop below its usual level is a real change, such as cooking
  fumes, fresh paint or a closed-up room. The usual level is the median of the last
  week of readings and the current level the median of the last few minutes, so a
  single noisy sample never raises it. It stays quiet (`nil`) until a day of history
  exists, and unless the air has dropped by a good margin.
  """
  import Ecto.Query, only: [from: 2]

  alias Trygg.Devices.Reading
  alias Trygg.Repo

  @window_days 7
  @recent_minutes 10
  @min_recent_readings 3
  @min_baseline_readings 1_000
  @min_baseline_span_seconds 24 * 3600
  # Air this far below the usual level (as a share of it) is worth a mention.
  @drop_threshold 0.35

  @doc """
  The alert for a device, or `nil` when there is nothing unusual to say: `%{percent_below:
  42, usual_ohms: 118_000.0, current_ohms: 68_000.0}`.
  """
  def alert(device_id, now \\ DateTime.utc_now()) do
    recent_from = DateTime.add(now, -@recent_minutes, :minute)
    baseline_from = DateTime.add(now, -@window_days, :day)

    evaluate(baseline(device_id, baseline_from, recent_from), recent(device_id, recent_from))
  end

  @doc false
  def evaluate(%{median: usual, count: n, span_seconds: span}, %{median: current, count: m})
      when is_number(usual) and is_number(current) and usual > 0 and
             n >= @min_baseline_readings and span >= @min_baseline_span_seconds and
             m >= @min_recent_readings do
    drop = 1 - current / usual

    if drop >= @drop_threshold,
      do: %{percent_below: round(drop * 100), usual_ohms: usual, current_ohms: current}
  end

  def evaluate(_baseline, _recent), do: nil

  # Everything from the window start up to the recent stretch: the recent samples are
  # what is being judged, so they must not drag the usual level towards themselves.
  defp baseline(device_id, from, until) do
    from(r in Reading,
      where: r.device_id == ^device_id and not is_nil(r.gas_ohms),
      where: r.measured_at >= ^from and r.measured_at < ^until,
      select: %{
        median: fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", r.gas_ohms),
        count: count(r.id),
        first: min(r.measured_at),
        last: max(r.measured_at)
      }
    )
    |> Repo.one()
    |> then(fn
      %{first: %DateTime{} = first, last: last} = row ->
        Map.put(row, :span_seconds, DateTime.diff(last, first))

      row ->
        Map.put(row, :span_seconds, 0)
    end)
  end

  defp recent(device_id, from) do
    from(r in Reading,
      where: r.device_id == ^device_id and not is_nil(r.gas_ohms) and r.measured_at >= ^from,
      select: %{
        median: fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", r.gas_ohms),
        count: count(r.id)
      }
    )
    |> Repo.one()
  end
end
