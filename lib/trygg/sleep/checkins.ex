defmodule Trygg.Sleep.Checkins do
  @moduledoc """
  The check-in ("pop-in") timing of a waking, as a pure function of its events.

  A waking's `events` are `%{"kind" => kind, "at" => iso8601}` with `kind` one of
  `"cry"` (crying started, or started again), `"pop_in"` (you went in),
  `"calm"` (crying turned to calming or whining: wait, don't go in) and
  `"asleep"`. From them `state/3` works out where the waking stands: whether
  they're crying, when the next pop-in is due (`Trygg.Sleep.Abcs.checkin_interval/1`
  after the crying started, then after each pop-in), how many pop-ins there have
  been and how long they've cried in total.

  The sequence starts over with each new waking, not within one.
  """

  alias Trygg.Sleep.Abcs

  @kinds ~w(cry pop_in calm asleep)

  @doc "The event kinds."
  def kinds, do: @kinds

  @doc "Builds an event for `kind` at `at`."
  def event(kind, %DateTime{} = at) when kind in @kinds,
    do: %{"kind" => kind, "at" => DateTime.to_iso8601(at)}

  @doc """
  The state of a waking at `now`:

      %{phase, pop_ins, next_due_at, cry_seconds, started_at, asleep_at}

  `phase` is `:crying`, `:calming` or `:asleep` (`:waiting` before any event);
  `next_due_at` is `nil` unless crying; `cry_seconds` counts every stretch from a
  `cry` to the following `calm` or `asleep` (to `now` while it's still going).
  """
  def state(events, %DateTime{} = now, _night \\ nil) when is_list(events) do
    parsed = Enum.map(events, &parse/1)
    {phase, anchor} = phase(parsed)
    pop_ins = Enum.count(parsed, &(&1.kind == "pop_in"))

    %{
      phase: phase,
      pop_ins: pop_ins,
      next_due_at:
        if(phase == :crying, do: DateTime.add(anchor, Abcs.checkin_interval(pop_ins), :second)),
      cry_seconds: cry_seconds(parsed, now),
      started_at: parsed |> List.first() |> then(&(&1 && &1.at)),
      asleep_at: parsed |> Enum.find(&(&1.kind == "asleep")) |> then(&(&1 && &1.at)),
      pop_in_times: for(e <- parsed, e.kind == "pop_in", do: e.at)
    }
  end

  # The phase, and the time the current interval is counted from: the latest
  # `cry` or `pop_in`.
  defp phase([]), do: {:waiting, nil}

  defp phase(parsed) do
    case List.last(parsed).kind do
      "asleep" ->
        {:asleep, nil}

      "calm" ->
        {:calming, nil}

      _ ->
        {:crying,
         parsed |> Enum.filter(&(&1.kind in ["cry", "pop_in"])) |> List.last() |> Map.fetch!(:at)}
    end
  end

  defp cry_seconds(parsed, now) do
    {total, started} =
      Enum.reduce(parsed, {0, nil}, fn
        %{kind: "cry", at: at}, {total, nil} ->
          {total, at}

        %{kind: "cry"}, acc ->
          acc

        %{kind: kind, at: at}, {total, started}
        when kind in ["calm", "asleep"] and not is_nil(started) ->
          {total + max(DateTime.diff(at, started, :second), 0), nil}

        _event, acc ->
          acc
      end)

    if started, do: total + max(DateTime.diff(now, started, :second), 0), else: total
  end

  defp parse(%{"kind" => kind, "at" => at}) do
    {:ok, dt, _} = DateTime.from_iso8601(at)
    %{kind: kind, at: dt}
  end
end
