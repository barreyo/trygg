defmodule Trygg.Reports.DayPlan do
  @moduledoc """
  The whole sleep day in one ordered list: this morning's wake-up, the naps
  that have happened (and the one running now), then the naps and bedtime still
  to come, predicted from the current conditions by `Trygg.Reports.Insights`.

  Each item is

      %{id, kind, state, ordinal, start, end, seconds, estimate?, range,
        source, awake_before, shifted_by_seconds}

  where `kind` is `:wake | :nap | :bed` and `state` is `:done`, `:now` (a nap
  running), `:due` (the next nap, with the wake window open) or `:upcoming`.
  `range` is `%{from, to}` for the next nap, `awake_before` the seconds awake
  leading into a nap or bedtime, and `shifted_by_seconds` how much earlier an
  estimated bedtime was pulled because the day is short on sleep.

  An estimated bedtime before 17:00 local time is left out: with only a day or
  two of history the model can land on one mid-afternoon, and showing it would
  only mislead.

  Pure: takes the child, their `%Day{}` for today, the `Insights` prediction and
  now.
  """

  alias Trygg.Families.Child
  alias Trygg.Reports.Day

  @doc """
  Builds the plan. `prediction` may be `nil` (no history yet), in which case only
  what has already happened is listed.
  """
  def build(%Child{} = child, %Day{} = today, prediction, %DateTime{} = now) do
    done = done_items(today, now)

    items =
      [wake_item(today, prediction, now)]
      |> Kernel.++(done)
      |> Kernel.++(today |> upcoming_items(prediction, now) |> after_last_nap(done))
      |> Enum.reject(&implausible_bedtime?(&1, child))
      |> Enum.reject(&is_nil/1)
      |> link_awake()

    %{items: items, day_sleep_seconds: today.day_sleep_seconds || 0}
  end

  @earliest_bedtime_minutes 17 * 60

  defp implausible_bedtime?(%{kind: :bed, estimate?: true, start: at}, child) do
    local = DateTime.shift_zone!(at, child.timezone)
    local.hour * 60 + local.minute < @earliest_bedtime_minutes
  end

  defp implausible_bedtime?(_item, _child), do: false

  defp wake_item(%Day{morning_wake: %DateTime{} = at}, _prediction, _now) do
    item("wake", :wake, :done, %{start: at, estimate?: false})
  end

  defp wake_item(_today, %{morning_wake: %{at: at}}, now) do
    state = if DateTime.compare(at, now) == :gt, do: :upcoming, else: :done
    item("wake", :wake, state, %{start: at, estimate?: true})
  end

  defp wake_item(_today, _prediction, _now), do: nil

  defp done_items(%Day{} = today, now) do
    naps =
      for nap <- today.naps do
        item("nap-#{nap.ordinal}", :nap, if(nap.running?, do: :now, else: :done), %{
          ordinal: nap.ordinal,
          start: nap.start,
          end: nap.end,
          seconds: nap.seconds,
          estimate?: false
        })
      end

    if bed_done?(today, now),
      do: naps ++ [item("bed", :bed, :done, %{start: today.bedtime, estimate?: false})],
      else: naps
  end

  # A nap that has just started can be running before the prediction knows it
  # (a sleep's first second isn't counted as asleep yet), so it may still list
  # that nap as upcoming. What has happened wins.
  defp after_last_nap(upcoming, done) do
    last =
      done |> Enum.filter(&(&1.kind == :nap)) |> Enum.map(& &1.ordinal) |> Enum.max(fn -> 0 end)

    Enum.reject(upcoming, &(&1.kind == :nap and &1.ordinal <= last))
  end

  defp bed_done?(%Day{bedtime: %DateTime{} = at}, now), do: DateTime.compare(at, now) != :gt
  defp bed_done?(%Day{}, _now), do: false

  defp upcoming_items(_today, nil, _now), do: []

  defp upcoming_items(%Day{} = today, prediction, now) do
    bed_done? = bed_done?(today, now)

    scheduled = Enum.reject(prediction.schedule, &(bed_done? and &1.kind == :bed))

    {items, _first?} =
      Enum.map_reduce(scheduled, true, fn
        %{kind: :nap} = entry, first? ->
          {nap_item(entry, prediction, first?, now), false}

        %{kind: :bed} = entry, first? ->
          {bed_item(entry, prediction), first?}
      end)

    items ++ bed_fallback(items, bed_done?, prediction)
  end

  # `prediction.schedule` carries bedtime only when there is a typical nap count;
  # still show a bedtime estimate if the model has one.
  defp bed_fallback(items, bed_done?, prediction) do
    cond do
      bed_done? ->
        []

      Enum.any?(items, &(&1.kind == :bed)) ->
        []

      match?(%{at: _}, prediction.bedtime) ->
        [bed_item(%{start: prediction.bedtime.at}, prediction)]

      true ->
        []
    end
  end

  defp nap_item(entry, prediction, first?, now) do
    pressure = prediction.wake_pressure

    due? =
      (first? and prediction.state == :awake and pressure) &&
        pressure.state in [:approaching, :past]

    range =
      case prediction.next_nap do
        %{ordinal: ordinal, range: %{from: from, to: to}}
        when first? and ordinal == entry.ordinal ->
          # A window that has already closed isn't worth showing: the nap is
          # simply due now.
          if DateTime.compare(to, now) == :lt, do: nil, else: %{from: from, to: to}

        _ ->
          nil
      end

    length = DateTime.diff(entry.end, entry.start, :second)

    item("nap-#{entry.ordinal}", :nap, if(due?, do: :due, else: :upcoming), %{
      ordinal: entry.ordinal,
      start: entry.start,
      end: entry.end,
      seconds: if(length > 0, do: length),
      estimate?: true,
      range: range,
      source: if(first? and prediction.next_nap, do: prediction.next_nap.source)
    })
  end

  defp bed_item(entry, prediction) do
    bed = prediction.bedtime || %{}

    item("bed", :bed, :upcoming, %{
      start: entry.start,
      estimate?: true,
      source: bed[:source],
      shifted_by_seconds: bed[:shifted_by_seconds]
    })
  end

  defp item(id, kind, state, attrs) do
    Map.merge(
      %{
        id: id,
        kind: kind,
        state: state,
        ordinal: nil,
        start: nil,
        end: nil,
        seconds: nil,
        estimate?: false,
        range: nil,
        source: nil,
        awake_before: nil,
        shifted_by_seconds: nil
      },
      attrs
    )
  end

  # Awake time leading into each nap or bedtime: from the wake-up, or from the
  # end of the previous nap. A running nap has no end yet, so nothing follows it
  # until it finishes (its projected end isn't known here).
  defp link_awake(items) do
    {linked, _awake_from} =
      Enum.map_reduce(items, nil, fn
        %{kind: :wake} = it, _from ->
          {it, it.start}

        %{kind: :nap} = it, from ->
          {with_awake(it, from), it.end}

        %{kind: :bed} = it, from ->
          {with_awake(it, from), nil}
      end)

    linked
  end

  defp with_awake(it, nil), do: it

  defp with_awake(it, from) do
    seconds = DateTime.diff(it.start, from, :second)
    if seconds > 0, do: %{it | awake_before: seconds}, else: it
  end
end
