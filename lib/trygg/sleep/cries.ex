defmodule Trygg.Sleep.Cries do
  @moduledoc """
  The C.R.I.E.S. calming sequence from Taking Cara Babies' "What do I do when
  my baby cries?" sheet, for the newborn phase (the guide says most families
  stop finding it useful by about 12 weeks, when S.I.T. B.A.C.K. takes over).

  The step names are the guide's; the one-line explanations are ours.
  """

  @steps [
    %{
      letter: "C",
      name: "Contain",
      detail: "Swaddle, or hold their arms gently in, so they feel held together."
    },
    %{
      letter: "R",
      name: "Roll onto their side",
      detail:
        "Only while you're holding them, to calm them. Always lay them down to sleep on their back."
    },
    %{
      letter: "I",
      name: "Introduce movement",
      detail: "Slow, small rocking or bouncing, like the motion they knew before birth."
    },
    %{
      letter: "E",
      name: "External sound",
      detail: "Shushing or steady white noise, close to their ear and fairly loud."
    },
    %{
      letter: "S",
      name: "Suck",
      detail: "A pacifier or a clean finger, if they take one."
    }
  ]

  @doc "The five steps, in order."
  def steps, do: @steps
end
