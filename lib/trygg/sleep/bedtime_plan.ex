defmodule Trygg.Sleep.BedtimePlan do
  @moduledoc """
  Bedtime planning from the 3–4 month guide: aim for 7–8 pm (the "magic
  window" when babies fall asleep easiest and stay asleep longest), shift a
  later bedtime earlier by 10–15 minutes each evening, and end the last nap
  100–120 minutes before bed.

  Pure and in minutes since local midnight, so a screen can render the steps
  without re-deriving them.
  """

  @shift_step 15

  @doc """
  `build(table, usual)` where `table` is a `Trygg.Sleep.Schedules` table and
  `usual` the child's usual bedtime in minutes since local midnight (or `nil`
  without history). Returns

      %{window: {lo, hi}, usual, status, tonight, steps, last_nap_by}

  `status` is `:within`, `:late`, `:early` or `:unknown`. `tonight` is the
  bedtime to aim for tonight (`usual` shifted 15 minutes earlier while it is
  late, held inside the window otherwise) and `steps` the evenings that follow,
  each `%{evening, minutes}` with `evening` counting from 1 (tonight), until the
  window is reached. `last_nap_by` is `{earliest, latest}` for when the last nap
  should end to keep `tonight` (bedtime minus the guide's gap).
  """
  def build(table, usual) do
    {lo, hi} = table.bedtime
    {gap_lo, gap_hi} = table.bed_gap

    {status, tonight, steps} = shift(usual, lo, hi)

    %{
      window: {lo, hi},
      usual: usual,
      status: status,
      tonight: tonight,
      steps: steps,
      last_nap_by: tonight && {tonight - gap_hi, tonight - gap_lo}
    }
  end

  defp shift(nil, _lo, _hi), do: {:unknown, nil, []}

  defp shift(usual, lo, hi) when usual > hi do
    steps =
      Stream.iterate(usual - @shift_step, &(&1 - @shift_step))
      |> Enum.reduce_while([], fn minutes, acc ->
        minutes = max(minutes, hi)
        acc = acc ++ [minutes]
        if minutes <= hi, do: {:halt, acc}, else: {:cont, acc}
      end)
      |> Enum.with_index(1)
      |> Enum.map(fn {minutes, evening} -> %{evening: evening, minutes: minutes} end)

    _ = lo
    {:late, hd(steps).minutes, steps}
  end

  defp shift(usual, lo, _hi) when usual < lo, do: {:early, usual, []}
  defp shift(usual, _lo, _hi), do: {:within, usual, []}

  @doc "Formats minutes since midnight as `HH:MM`."
  def clock(minutes) when is_integer(minutes) do
    :io_lib.format("~2..0B:~2..0B", [div(minutes, 60), rem(minutes, 60)]) |> IO.iodata_to_binary()
  end
end
