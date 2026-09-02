defmodule Trygg.Units do
  @moduledoc """
  Conversion between canonical storage units (always metric) and a user's
  preferred display units.

  Storage canon:

    * `:volume` -> millilitres (`ml`)
    * `:weight` -> grams (`g`)
    * `:length` -> centimetres (`cm`)

  Metric *display* for weight is kilograms, so `to_display/3` / `from_display/3`
  convert g ↔ kg. Volume and length already match their display labels.
  """

  @ml_per_oz 29.5735295625
  @g_per_lb 453.59237
  @cm_per_in 2.54

  @type kind :: :volume | :weight | :length
  @type system :: :metric | :imperial

  @doc """
  Returns the short unit label shown next to an input/value for the given
  `kind` and `system`.
  """
  @spec unit_label(kind, system) :: String.t()
  def unit_label(:volume, :metric), do: "ml"
  def unit_label(:volume, :imperial), do: "oz"
  def unit_label(:weight, :metric), do: "kg"
  def unit_label(:weight, :imperial), do: "lb"
  def unit_label(:length, :metric), do: "cm"
  def unit_label(:length, :imperial), do: "in"

  @doc """
  Converts a canonical (metric) value into the user's preferred `system`.

  Returns a float rounded to a sensible precision for display. Returns `nil`
  when given `nil`.
  """
  @spec to_display(number | nil, kind, system) :: float | nil
  def to_display(nil, _kind, _system), do: nil

  def to_display(value, :weight, :metric) when is_number(value),
    do: round_to(value / 1000, 3)

  def to_display(value, _kind, :metric) when is_number(value), do: round_to(value * 1.0, 1)

  def to_display(value, :volume, :imperial) when is_number(value),
    do: round_to(value / @ml_per_oz, 1)

  def to_display(value, :weight, :imperial) when is_number(value),
    do: round_to(value / @g_per_lb, 2)

  def to_display(value, :length, :imperial) when is_number(value),
    do: round_to(value / @cm_per_in, 2)

  @doc """
  Converts a value entered by the user in `system` back into the canonical
  (metric) unit for storage. Returns `nil` when given `nil`.
  """
  @spec from_display(number | nil, kind, system) :: float | nil
  def from_display(nil, _kind, _system), do: nil

  def from_display(value, :weight, :metric) when is_number(value), do: value * 1000.0

  def from_display(value, _kind, :metric) when is_number(value), do: value * 1.0

  def from_display(value, :volume, :imperial) when is_number(value),
    do: value * @ml_per_oz

  def from_display(value, :weight, :imperial) when is_number(value),
    do: value * @g_per_lb

  def from_display(value, :length, :imperial) when is_number(value),
    do: value * @cm_per_in

  @doc """
  Formats a canonical value for display, e.g. `"90 ml"` or `"3 oz"`.
  Trailing `.0` is dropped.
  """
  @spec format(number | nil, kind, system) :: String.t() | nil
  def format(nil, _kind, _system), do: nil

  def format(value, kind, system) when is_number(value) do
    number = value |> to_display(kind, system) |> trim_float()
    "#{number} #{unit_label(kind, system)}"
  end

  defp round_to(float, places) do
    Float.round(float, places)
  end

  defp trim_float(float) when is_float(float) do
    if float == Float.round(float), do: trunc(float), else: float
  end

  defp trim_float(other), do: other
end
