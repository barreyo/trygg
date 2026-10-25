defmodule Trygg.TimeFormat do
  @moduledoc """
  How a caregiver wants clock times shown: `:h24` (`14:05`) or `:h12`
  (`2:05 PM`). Storage and `<input type="time">` values are always 24-hour;
  this only shapes what people read.

  Clock labels are built all over the app, including deep in the report layer,
  so the signed-in user's choice is kept in the process dictionary rather than
  threaded through every call. `TryggWeb.UserAuth` sets it once per request
  (plug) and once per LiveView mount (`on_mount`), and every function here
  reads it when no format is passed. Pass a format explicitly to override it.
  """

  @type t :: :h24 | :h12

  @key {__MODULE__, :format}

  @doc "The supported formats."
  @spec formats() :: [t]
  def formats, do: [:h24, :h12]

  @doc "Sets the format for the current process (`nil` resets to the default)."
  @spec put(t | nil) :: :ok
  def put(format) when format in [:h24, :h12] do
    Process.put(@key, format)
    :ok
  end

  def put(_), do: put(:h24)

  @doc "The current process's format, 24-hour unless one was set."
  @spec get() :: t
  def get, do: Process.get(@key, :h24)

  @doc ~S"""
  The `Calendar.strftime/2` pattern for a time of day: `"%H:%M"` or
  `"%-I:%M %p"`.
  """
  @spec pattern(t) :: String.t()
  def pattern(format \\ get())
  def pattern(:h24), do: "%H:%M"
  def pattern(:h12), do: "%-I:%M %p"

  @doc """
  A time of day from minutes since midnight, a `Time`, or anything
  `Calendar.strftime/2` accepts (`DateTime`, `NaiveDateTime`).
  Minutes wrap at 24 hours.
  """
  @spec clock(non_neg_integer | float | Calendar.time(), t) :: String.t()
  def clock(value, format \\ get())

  def clock(minutes, format) when is_number(minutes) do
    minutes = minutes |> round() |> Integer.mod(24 * 60)
    clock(Time.new!(div(minutes, 60), rem(minutes, 60), 0), format)
  end

  def clock(value, format), do: Calendar.strftime(value, pattern(format))

  @doc "Like `clock/2`, but `nil` stays `nil`."
  @spec clock_or_nil(term, t) :: String.t() | nil
  def clock_or_nil(value, format \\ get())
  def clock_or_nil(nil, _format), do: nil
  def clock_or_nil(value, format), do: clock(value, format)

  @doc "The end of a day on a chart axis: `\"24:00\"` or `\"12:00 AM\"`."
  @spec end_of_day(t) :: String.t()
  def end_of_day(format \\ get())
  def end_of_day(:h24), do: "24:00"
  def end_of_day(:h12), do: clock(0, :h12)

  @doc """
  A short axis label for a whole hour: `"02"` in 24-hour, `"2a"` / `"12p"` in
  12-hour.
  """
  @spec hour_label(0..23, t) :: String.t()
  def hour_label(hour, format \\ get())
  def hour_label(hour, :h24), do: hour |> Integer.to_string() |> String.pad_leading(2, "0")
  def hour_label(hour, :h12), do: "#{h12_hour(hour)}#{if hour < 12, do: "a", else: "p"}"

  defp h12_hour(hour) do
    case rem(hour, 12) do
      0 -> 12
      h -> h
    end
  end

  @doc "Human label for a format, for the preferences screen."
  @spec label(t) :: String.t()
  def label(:h24), do: "24-hour"
  def label(:h12), do: "12-hour"

  @doc "An example of a format, for the preferences screen."
  @spec example(t) :: String.t()
  def example(format), do: clock(~T[14:30:00], format)
end
