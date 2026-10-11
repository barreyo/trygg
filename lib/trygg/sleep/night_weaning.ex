defmodule Trygg.Sleep.NightWeaning do
  @moduledoc """
  The night-weaning schedule that goes with the ABCs plan ("C.U.T. F.E.E.D.S."):
  wean every night feed over about five nights, a little less each night, giving
  each feed only when the baby is asleep, with the last one before 11 pm.

  `generate/3` builds a table for the baby's current night feeds: the times,
  and for each night the amount to offer (`nil` once a feed is dropped). The
  guide gives example tables; this follows their shape for any starting amount:

    * one feed: dropped on night 5, in four steps (a time 30–60 minutes before
      they naturally wake);
    * two feeds: the first dropped on night 4, the second on night 5;
    * three feeds: dropped on nights 5, 4 and 6.

  Amounts are minutes for nursing and millilitres for a bottle, and come out as
  whole minutes (or whole 5 ml steps for a bottle). It is a suggestion to adjust
  with your pediatrician, not a prescription.
  """

  @doc """
  `generate(kind, feeds, opts)` where `kind` is `:nursing` or `:bottle` and
  `feeds` a list of `{minutes_after_midnight, starting_amount}` in the order they
  happen, evening first (1 to 3 feeds).

  Returns `%{kind, nights, rows}` with one row per feed:
  `%{time, amounts}`, where `amounts` is a list of `nights` values (`nil` = no
  feed). Raises `ArgumentError` for no feeds or more than three.
  """
  def generate(kind, feeds, _opts \\ []) when kind in [:nursing, :bottle] and is_list(feeds) do
    if feeds == [] or length(feeds) > 3, do: raise(ArgumentError, "one to three night feeds")

    off = drop_nights(length(feeds))

    rows =
      for {{time, amount}, off_night} <- Enum.zip(feeds, off) do
        %{time: time, amounts: amounts(kind, amount, off_night, length(feeds))}
      end

    %{kind: kind, nights: rows |> Enum.map(&length(&1.amounts)) |> Enum.max(), rows: rows}
  end

  # The night each feed is dropped on (it still happens on every night before).
  defp drop_nights(1), do: [5]
  defp drop_nights(2), do: [4, 5]
  defp drop_nights(3), do: [5, 4, 6]

  # Amounts for nights 1..(off - 1) falling from `start` to a floor, then nil
  # from `off` on, padded to the longest table (six nights for three feeds).
  defp amounts(kind, start, off, feeds) do
    total = if feeds == 3, do: 6, else: 5
    steps = off - 1
    floor = max(unit(kind), round(start * floor_fraction(off)))

    reduced =
      for night <- 1..steps do
        if steps == 1 do
          start
        else
          value = start - (start - floor) * (night - 1) / (steps - 1)
          snap(kind, value)
        end
      end
      |> strictly_decreasing(unit(kind))

    reduced ++ List.duplicate(nil, total - steps)
  end

  defp floor_fraction(4), do: 0.5
  defp floor_fraction(5), do: 0.35
  defp floor_fraction(6), do: 0.3
  defp floor_fraction(_), do: 0.5

  # One step: a minute of nursing, or 5 ml of bottle.
  defp unit(:nursing), do: 1
  defp unit(:bottle), do: 5

  defp snap(:nursing, value), do: max(round(value), 1)
  defp snap(:bottle, value), do: max(round(value / 5) * 5, 5)

  # Each night is at least one step lower than the last, down to one step.
  defp strictly_decreasing(values, unit) do
    {out, _} =
      Enum.map_reduce(values, nil, fn
        v, nil -> {v, v}
        v, prev -> {max(min(v, prev - unit), unit), max(min(v, prev - unit), unit)}
      end)

    out
  end

  @doc """
  Default feed times for `n` night feeds: evening and early-hours times that keep
  the last feed before 11 pm after the first week: `[22:30, 03:30]` for two,
  `[22:00, 01:00, 04:00]` for three, and one feed 45 minutes before `natural`
  (minutes after midnight) when they wake by themselves (default 01:15 → 00:30).
  """
  def default_times(n, natural \\ 75)
  def default_times(1, natural), do: [max(natural - 45, 0)]
  def default_times(2, _natural), do: [22 * 60 + 30, 3 * 60 + 30]
  def default_times(3, _natural), do: [22 * 60, 60, 4 * 60]
end
