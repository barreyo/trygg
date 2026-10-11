defmodule Trygg.Sleep.Definitions do
  @moduledoc """
  The sleep-training plans the engine can run, behind one set of questions: how
  old they need to be, whether a pediatrician's go-ahead is needed, which
  pre-flight items to tick, how many nights, and how check-ins in night mode are
  timed.

    * `:swap` — a gradual plan (`Trygg.Sleep.Swap`), from 2 months, nothing is
      cut so no go-ahead is required.
    * `:slip` — the *Precious Little Sleep* plan (`Trygg.Sleep.Slip`), from 4 months.
    * `:abcs` — "The ABCs of Sleep" (`Trygg.Sleep.Abcs`), from 5 months.

  The engine (`Trygg.Sleep.Plans`) never asks which; it asks this module.
  """

  alias Trygg.Sleep.{Abcs, Plan, Slip, Swap}

  # Gentlest first.
  @ids [:swap, :slip, :abcs]

  @doc "The plan ids, gentlest first."
  def ids, do: @ids

  @doc "The plan's display name."
  def name(:swap), do: Swap.definition().name
  def name(:slip), do: Slip.definition().name
  def name(:abcs), do: Abcs.definition().name

  @doc "A short name for headings and buttons."
  def short_name(:swap), do: "Gradual (SWAP)"
  def short_name(:slip), do: "SLIP"
  def short_name(:abcs), do: "ABCs of Sleep"

  @doc "The corrected age in days from which the plan opens."
  def min_age_days(:swap), do: Swap.min_age_days()
  def min_age_days(:slip), do: Slip.min_age_days()
  def min_age_days(:abcs), do: Abcs.min_age_days()

  @doc "Whether starting needs the pediatrician's go-ahead recorded."
  def needs_clearance?(:swap), do: false
  def needs_clearance?(_), do: true

  @doc "The pre-flight checklist as `{id, text}`."
  def preflight(:swap), do: Swap.preflight()
  def preflight(:slip), do: Slip.preflight()
  def preflight(:abcs), do: Abcs.preflight()

  @doc "The ids of the pre-flight items."
  def preflight_ids(definition), do: definition |> preflight() |> Enum.map(&elem(&1, 0))

  @doc "Every pre-flight id across all plans (the ones a parent can tick on the plan page)."
  def all_preflight_ids, do: Enum.flat_map(@ids, &preflight_ids/1)

  @doc "How many nights the plan runs."
  def nights(%Plan{definition: :slip}), do: Slip.nights()
  def nights(%Plan{definition: :swap, options: options}), do: Swap.nights(options["variant"])
  def nights(%Plan{}), do: Abcs.nights()

  @doc """
  How check-ins in night mode are timed on night `night` of `plan`:

    * `:abcs` — 5, 10, then every 15 minutes (`Trygg.Sleep.Abcs`).
    * `{:five_minute, night}` — the graduated SLIP, growing with the night.
    * `:none` — a full SLIP: no visits at all.
    * `:manual` — a SWAP: you decide when to help, nothing is timed.
  """
  def schedule(%Plan{definition: :slip, options: options}, night) do
    if options["mode"] == "full", do: :none, else: {:five_minute, max(night, 1)}
  end

  def schedule(%Plan{definition: :swap}, _night), do: :manual
  def schedule(%Plan{}, _night), do: :abcs

  @doc "Whether night mode should offer a button to record that you went in."
  def visits?(%Plan{definition: :slip, options: %{"mode" => "full"}}), do: false
  def visits?(%Plan{}), do: true
end
