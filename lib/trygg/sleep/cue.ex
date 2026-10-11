defmodule Trygg.Sleep.Cue do
  @moduledoc """
  The three states of sleepiness a caregiver can note when a sleep starts,
  from Taking Cara Babies' "Understanding Sleepy Cues" sheet: *tired*, *ready
  for a nap* and *overtired*. The id is stored on the sleep entry as
  `data["cue"]`.

  Newborn guidance is to start a nap as soon as the cues appear and avoid
  letting a baby tip into overtired; noting the cue lets Home show how often
  that happens and how long they had been awake when they were "ready".
  """

  @cues [
    %{
      id: "tired",
      label: "Tired",
      short: "Tired cues",
      title: "I'm tired",
      signs: ["The stare", "Pink brows", "Looks away"]
    },
    %{
      id: "ready",
      label: "Ready",
      short: "Ready cues",
      title: "I'm ready for a nap",
      signs: ["Fussiness", "Big yawns", "Rubs eyes"]
    },
    %{
      id: "overtired",
      label: "Overtired",
      short: "Overtired",
      title: "I'm overtired",
      signs: ["Frantic screaming", "Rigid body", "Pushes away"]
    }
  ]

  @ids Enum.map(@cues, & &1.id)

  @doc "Every cue, in order from least to most tired."
  def all, do: @cues

  @doc "The valid cue ids."
  def ids, do: @ids

  @doc "Whether `id` is a known cue."
  def valid?(id), do: id in @ids

  @doc "Chip label for a cue id, or `nil`."
  def label(id), do: field(id, :label)

  @doc "Short phrase for a cue id used in an entry's detail line, or `nil`."
  def short(id), do: field(id, :short)

  defp field(id, key) do
    case Enum.find(@cues, &(&1.id == id)) do
      nil -> nil
      cue -> Map.fetch!(cue, key)
    end
  end
end
