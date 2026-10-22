defmodule Trygg.Devices.AirQuality do
  @moduledoc """
  Bosch's indoor air quality index (0 clean .. 500 bad) in words and colours.

  One list of bands is the source for the word on the Today tile and for the coloured
  regions behind the graph on the device page, so the two always agree. `tone` names
  a theme colour and `opacity` how strongly the graph tints the band. `level` is the
  coarser four-step green/yellow/orange/red the status bar on every screen is painted in.
  """

  @bands [
    %{from: 0, to: 50, label: "Excellent", tone: "success", level: :green, opacity: 0.22},
    %{from: 50, to: 100, label: "Good", tone: "success", level: :green, opacity: 0.1},
    %{from: 100, to: 150, label: "Fair", tone: "warning", level: :yellow, opacity: 0.12},
    %{from: 150, to: 200, label: "Poor", tone: "warning", level: :orange, opacity: 0.24},
    %{from: 200, to: 250, label: "Bad", tone: "error", level: :red, opacity: 0.16},
    %{from: 250, to: 500, label: "Very bad", tone: "error", level: :red, opacity: 0.28}
  ]

  @doc "The bands, cleanest first."
  def bands, do: @bands

  @doc "The band an index falls in (an index on a boundary belongs to the cleaner band)."
  def band(iaq) when is_number(iaq),
    do: Enum.find(@bands, List.last(@bands), &(iaq <= &1.to))

  @doc "The status bar colour for an index: `:green`, `:yellow`, `:orange` or `:red`."
  def level(iaq) when is_number(iaq), do: band(iaq).level

  @doc "The word for an index, like \"Good\"."
  def label(iaq) when is_number(iaq), do: band(iaq).label
end
