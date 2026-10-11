defmodule Trygg.Sleep.SafeSleep do
  @moduledoc """
  The safe-sleep checklist: the practical steps from *Precious Little Sleep* and
  the American Academy of Pediatrics guidance it follows for lowering the risk
  of SIDS and accidents. Every item is ticked by hand (they're facts about the
  room and the house), and remembered in `children.sleep_checks` under `ss-…`
  ids.

  This isn't medical advice; the app doesn't try to measure any of it. It's a
  list to run through, to show the pediatrician, and to give every caregiver.
  """

  # {id, text}
  @items [
    {"ss-back", "Always on their back to sleep, for naps and nights, until a year."},
    {"ss-flat",
     "A firm, flat surface made for babies (crib, bassinet or play yard that meets safety standards), with a fitted sheet and nothing under it."},
    {"ss-bare",
     "Nothing else in there: no pillows, blankets, bumpers, stuffed toys or sleep positioners."},
    {"ss-temp",
     "Not too warm: no more layers than you'd wear. Flushed cheeks and a sweaty neck mean too hot."},
    {"ss-room", "They sleep in our room, not our bed, for at least the first six months."},
    {"ss-no-couch",
     "Nobody sleeps with them on a sofa or armchair, ever. If we might doze off, they go in the crib first."},
    {"ss-no-carseat",
     "Car seats, swings and bouncers aren't for sleeping. Move them to the crib when they nod off."},
    {"ss-cords", "No cords, blind strings or camera wires within reach of the crib."},
    {"ss-recall",
     "The crib or bassinet has been checked for recalls and is put together properly."},
    {"ss-paci", "We offer a pacifier for sleep (if they take one)."},
    {"ss-smoke-free", "Nobody smokes around them, and nobody smokes in the home or car."},
    {"ss-shots", "Their immunizations are up to date."},
    {"ss-caregivers", "Everyone who looks after them, including daycare, knows these rules."},
    {"ss-doctor", "We've shown the pediatrician a photo of where they sleep."}
  ]

  @cosleeping [
    "Never with a baby under four months, born early, or if either of you smokes, drinks or takes anything that makes you drowsy.",
    "Not with siblings, pets or anyone who isn't a parent.",
    "A firm mattress, no duvet or pillows near the baby, away from walls, ideally on the floor.",
    "Make the bed safe even if you never plan to share it: most parents fall asleep with their baby at some point."
  ]

  @doc "The items as `{id, text}`."
  def items, do: @items

  @doc "Ids of the items."
  def ids, do: Enum.map(@items, &elem(&1, 0))

  @doc "Notes for families who share a bed."
  def cosleeping_notes, do: @cosleeping

  @doc """
  `%{items, done, total}` for a child's `sleep_checks` map: each item is
  `%{id, text, checked?, auto?: false, detail: nil}` so it can be rendered
  with the same row as the other checklists.
  """
  def evaluate(ticks) do
    ticks = ticks || %{}

    items =
      for {id, text} <- @items do
        %{id: id, text: text, checked?: Map.has_key?(ticks, id), auto?: false, detail: nil}
      end

    %{items: items, done: Enum.count(items, & &1.checked?), total: length(items)}
  end
end
