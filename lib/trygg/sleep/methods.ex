defmodule Trygg.Sleep.Methods do
  @moduledoc """
  The step-by-step methods night mode walks through, as data.

    * `:cries` — for a newborn (about the first 12 weeks): C.R.I.E.S., five
      things to try in order. No timers.
    * `:sit_back` — from 13 weeks: S.I.T. B.A.C.K., the Taking Cara Babies
      sequence for helping a baby settle with as little help as needed. Each
      step has a time to give it before moving on.

  Step names come from the guides; the one-line explanations are ours. A step's
  `seconds` is how long to give it (`nil` when it isn't timed) and `max_seconds`
  how long it may stretch to.
  """

  alias Trygg.Sleep.Cries

  @sit_back [
    %{
      id: :stop,
      letter: "S",
      name: "Stop, wait, watch",
      detail:
        "Listen. Is it a real cry, or a fuss while they settle themselves? Give it a few minutes.",
      seconds: 300,
      max_seconds: 480
    },
    %{
      id: :increase_sound,
      letter: "I",
      name: "Increase the sound",
      detail: "Turn the sound machine up, or move it a little closer.",
      seconds: 120,
      max_seconds: 120
    },
    %{
      id: :touch,
      letter: "T",
      name: "Touch their chest",
      detail: "A firm, gentle hand on their chest. Breathe slowly and stay calm.",
      seconds: 120,
      max_seconds: 120
    },
    %{
      id: :binky,
      letter: "B",
      name: "Binky",
      detail: "Offer the pacifier if they take one. Don't keep replacing it if they spit it out.",
      seconds: 120,
      max_seconds: 120
    },
    %{
      id: :add_rocking,
      letter: "A",
      name: "Add rocking",
      detail: "Gently rock their body from side to side.",
      seconds: 120,
      max_seconds: 120
    },
    %{
      id: :cuddle,
      letter: "C",
      name: "Cuddle",
      detail: "Pick them up and bounce or rock gently. Put them down once they're calm.",
      seconds: 120,
      max_seconds: 120
    },
    %{
      id: :feed,
      letter: "K",
      name: "Feed, maybe",
      detail:
        "Only if a feed is due. If not, go back to the start and keep going. Skipping steps teaches them the quick fix is the only way.",
      seconds: nil,
      max_seconds: nil
    }
  ]

  @cries Enum.map(Cries.steps(), fn step ->
           %{
             id: step.name |> String.downcase() |> String.replace(" ", "_") |> String.to_atom(),
             letter: step.letter,
             name: step.name,
             detail: step.detail,
             seconds: nil,
             max_seconds: nil
           }
         end)

  @methods %{
    cries: %{id: :cries, label: "C.R.I.E.S.", steps: @cries},
    sit_back: %{id: :sit_back, label: "S.I.T. B.A.C.K.", steps: @sit_back},
    # Check-ins aren't a sequence of steps; see `Trygg.Sleep.Checkins`.
    abcs: %{id: :abcs, label: "ABCs check-ins", steps: []}
  }

  @doc "The method ids, in the order they're offered."
  def ids, do: [:cries, :sit_back, :abcs]

  @doc "The method with `id` (`%{id, label, steps}`), or `nil`."
  def get(id) when is_atom(id), do: Map.get(@methods, id)
  def get(_), do: nil

  @doc "The step at `index` (0-based) of a method, or `nil` past the end."
  def step(method_id, index) when is_integer(index) and index >= 0 do
    case get(method_id) do
      nil -> nil
      %{steps: steps} -> Enum.at(steps, index)
    end
  end

  def step(_method_id, _index), do: nil

  @doc "How many steps a method has."
  def count(method_id) do
    case get(method_id) do
      nil -> 0
      %{steps: steps} -> length(steps)
    end
  end

  @doc "The method to offer for a `Trygg.Sleep.Phase` id: C.R.I.E.S. for a newborn, S.I.T. B.A.C.K. after."
  def for_phase(:newborn), do: :cries
  def for_phase(_phase_id), do: :sit_back
end
