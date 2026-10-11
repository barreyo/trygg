defmodule Trygg.Sleep.Assist do
  @moduledoc """
  How much help a baby needed to fall asleep: the nine-step "sliding scale of
  intervention" from the Taking Cara Babies 3–4 month guide, from level 1 (fed,
  rocked or bounced to sleep) to level 9 (put down awake, fell asleep alone).

  Stored on a sleep entry as `data["assist"]` (1–9), with `data["settle_minutes"]`
  for how long it took after being put down. The guide's advice is to start
  where you are and move down one step when you can, and to move back up for a
  day if a step isn't working after 10–15 minutes.
  """

  @levels [
    {1, "Fed, rocked or bounced to sleep, put down asleep"},
    {2, "Fed to sleep, gently woken a little before going down"},
    {3, "Rocked to sleep in arms, woken a little before going down"},
    {4, "Rocked side to side in the crib until asleep"},
    {5, "Hand on chest while falling asleep in the crib"},
    {6, "Calmed with rocking or a hand on the chest, then removed before asleep"},
    {7, "Put down awake; picked up to calm after about 5 minutes of fussing, then down again"},
    {8, "Put down awake; helped only when crying out (S.I.T. B.A.C.K.)"},
    {9, "Put down awake and fell asleep independently"}
  ]

  # `{minutes, label}` for the time-to-settle choices.
  @settle [
    {5, "Under 5 min"},
    {10, "5–10 min"},
    {20, "10–20 min"},
    {30, "20–30 min"},
    {45, "Over 30 min"}
  ]

  @doc "Every level as `{number, description}`, most help first."
  def levels, do: @levels

  @doc "The time-to-settle choices as `{minutes, label}` (minutes is the bucket's upper end)."
  def settle_options, do: @settle

  @doc "Whether `level` is a valid 1–9 step."
  def valid?(level), do: is_integer(level) and level in 1..9

  @doc "Description of `level`, or `nil`."
  def label(level) do
    case List.keyfind(@levels, level, 0) do
      {_, text} -> text
      nil -> nil
    end
  end

  @doc "A short form for lists: \"Level 7\"."
  def short(level) when is_integer(level), do: "Level #{level}"
  def short(_), do: nil

  @doc "Label for a settle bucket, or `nil`."
  def settle_label(minutes) do
    case List.keyfind(@settle, minutes, 0) do
      {_, text} -> text
      nil -> nil
    end
  end

  @doc "The next step down the scale (less help), or `nil` at the end."
  def next_step(level) when is_integer(level) and level in 1..8, do: level + 1
  def next_step(_), do: nil
end
