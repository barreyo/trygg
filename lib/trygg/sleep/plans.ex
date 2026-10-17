defmodule Trygg.Sleep.Plans do
  @moduledoc """
  Starting, following and ending a sleep-training plan (`Trygg.Sleep.Plan`):
  "The ABCs of Sleep" (`Trygg.Sleep.Abcs`), the Sleep Learning Independence Plan
  (`Trygg.Sleep.Slip`) or a gradual Sleep With Assistance Plan
  (`Trygg.Sleep.Swap`). `Trygg.Sleep.Definitions` knows what each one needs.

  A plan only opens when all of these hold, and `eligibility/4` says which don't:
  the child is old enough (corrected age, per plan), a caregiver has recorded
  that the pediatrician is fine with sleep training
  (`children.sleep_training_cleared_on`; a gradual SWAP cuts nothing and doesn't
  need it), and every item of the plan's pre-flight checklist has been ticked.

  Writes need `:caregiver`; reads `:viewer`.
  """
  import Ecto.Query

  alias Trygg.Accounts.Scope
  alias Trygg.Families
  alias Trygg.Families.Child
  alias Trygg.Repo
  alias Trygg.Sleep.{Abcs, Definitions, NightWeaning, Plan, Slip, Swap}

  @doc "The plan being followed for `child`, or `nil`. Requires `:viewer`."
  def active(%Scope{} = scope, %Child{} = child) do
    Families.authorize!(scope, child, :viewer)

    Plan
    |> where([p], p.child_id == ^child.id and p.status == :active)
    |> Repo.one()
  end

  @doc "All of the child's plans, newest first. Requires `:viewer`."
  def list(%Scope{} = scope, %Child{} = child) do
    Families.authorize!(scope, child, :viewer)

    Plan
    |> where([p], p.child_id == ^child.id)
    |> order_by(desc: :started_on, desc: :id)
    |> Repo.all()
  end

  @doc """
  What stands between this child and starting a `definition` (`:abcs` by
  default): `%{age, clearance, needs_clearance?, preflight, ready?}`.

    * `age` — `{:ok, nil}` or `{:locked, unlock_date}` (nil without a birth date).
    * `clearance` — the date the pediatrician's go-ahead was recorded, or `nil`.
    * `needs_clearance?` — whether this plan needs it to start.
    * `preflight` — `%{done, total, missing}` over the plan's pre-flight checklist.
  """
  def eligibility(%Child{} = child, phase, %Date{} = today, definition \\ :abcs) do
    min_age = Definitions.min_age_days(definition)
    needs_clearance? = Definitions.needs_clearance?(definition)

    age =
      case phase do
        %{age_days: days} when days >= 0 ->
          if days >= min_age,
            do: {:ok, nil},
            else: {:locked, Date.add(today, min_age - days)}

        _ ->
          {:locked, nil}
      end

    ticks = child.sleep_checks || %{}
    ids = Definitions.preflight_ids(definition)
    missing = Enum.reject(ids, &Map.has_key?(ticks, &1))

    %{
      age: age,
      clearance: child.sleep_training_cleared_on,
      needs_clearance?: needs_clearance?,
      preflight: %{done: length(ids) - length(missing), total: length(ids), missing: missing},
      ready?:
        match?({:ok, _}, age) and
          (not needs_clearance? or not is_nil(child.sleep_training_cleared_on)) and missing == []
    }
  end

  @doc """
  Starts a plan for `child`, night 1 being the evening of `attrs[:started_on]`
  (default: today). `attrs[:definition]` is `:abcs` (default), `:slip` or `:swap`;
  `attrs[:options]` carries `"mode"` for a SLIP (`"graduated"` by default) or
  `"variant"` (and optionally `"start_minutes"`) for a SWAP; an ABCs plan may
  carry the night-weaning setup (`:feed_kind`, `:feed_times`, `:feed_amounts`).

  Returns `{:error, :not_ready}` unless `eligibility/4` says `ready?`, and
  `{:error, :already_active}` if a plan is already running.
  """
  def start(%Scope{} = scope, %Child{} = child, phase, attrs \\ %{}) do
    Families.authorize!(scope, child, :caregiver)
    today = Child.local_today(child)
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    definition = parse_definition(attrs["definition"])

    if definition && eligibility(child, phase, today, definition).ready? do
      attrs =
        attrs
        |> Map.put_new("started_on", today)
        |> Map.put("definition", Atom.to_string(definition))
        |> Map.put("status", "active")
        |> Map.update("options", default_options(definition), &options(definition, &1))

      %Plan{child_id: child.id, started_by_id: scope.user.id}
      |> Plan.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, plan} ->
          Families.broadcast(child.id, {:sleep_plan, :started, plan})
          {:ok, plan}

        {:error, %Ecto.Changeset{errors: [child_id: _]}} ->
          {:error, :already_active}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      {:error, :not_ready}
    end
  end

  defp parse_definition(nil), do: :abcs
  defp parse_definition(:abcs), do: :abcs
  defp parse_definition("abcs"), do: :abcs
  defp parse_definition(:slip), do: :slip
  defp parse_definition("slip"), do: :slip
  defp parse_definition(:swap), do: :swap
  defp parse_definition("swap"), do: :swap
  defp parse_definition(_), do: nil

  defp default_options(:slip), do: %{"mode" => "graduated"}
  defp default_options(_), do: %{}

  # Options with string keys; a SLIP mode defaults to graduated.
  defp options(definition, given) do
    given = Map.new(given || %{}, fn {k, v} -> {to_string(k), v} end)
    if definition == :slip, do: Map.put_new(given, "mode", "graduated"), else: given
  end

  @doc """
  Moves a graduated SLIP to full extinction (no more visits). Not the other
  way round: once you've decided not to go in, you don't start again. Requires
  `:caregiver`.
  """
  def go_full(%Scope{} = scope, %Plan{definition: :slip, options: options} = plan) do
    Families.authorize!(scope, child_for(plan), :caregiver)

    with {:ok, updated} <-
           plan |> Plan.changeset(%{options: Map.put(options, "mode", "full")}) |> Repo.update() do
      Families.broadcast(plan.child_id, {:sleep_plan, :changed, updated})
      {:ok, updated}
    end
  end

  @doc "Ends a plan as `:completed` or `:stopped` today. Requires `:caregiver`."
  def finish(%Scope{} = scope, %Plan{} = plan, status) when status in [:completed, :stopped] do
    child = child_for(plan)
    Families.authorize!(scope, child, :caregiver)

    # `child_for/1` is only an id; the end date needs the child's own time zone.
    child = Repo.get!(Child, plan.child_id)

    with {:ok, updated} <-
           plan
           |> Plan.changeset(%{status: status, ended_on: Child.local_today(child)})
           |> Repo.update() do
      Families.broadcast(plan.child_id, {:sleep_plan, :ended, updated})
      {:ok, updated}
    end
  end

  @doc "Sets (or, with blank text, clears) the note for night `night`. Requires `:caregiver`."
  def put_note(%Scope{} = scope, %Plan{} = plan, night, text) when is_integer(night) do
    Families.authorize!(scope, child_for(plan), :caregiver)
    key = Integer.to_string(night)
    text = String.trim(text || "")
    notes = if text == "", do: Map.delete(plan.notes, key), else: Map.put(plan.notes, key, text)

    plan |> Plan.changeset(%{notes: notes}) |> Repo.update()
  end

  @doc """
  The night of the plan at `now`: the evening of `started_on` is night 1, and the
  small hours belong to the evening before (before midday, it's still last
  night). `0` before night 1, and a number past `Abcs.nights/0` once it's over.
  """
  def night_number(%Plan{started_on: started}, %Child{} = child, %DateTime{} = now) do
    local = DateTime.shift_zone!(now, child.timezone)

    night_date =
      if local.hour < 12, do: Date.add(DateTime.to_date(local), -1), else: DateTime.to_date(local)

    max(Date.diff(night_date, started) + 1, 0)
  end

  @doc "The local date of the evening of night `n`."
  def night_date(%Plan{started_on: started}, n) when is_integer(n), do: Date.add(started, n - 1)

  @doc """
  What to do tonight, at `now`: `%{night, nights, date, finished?}` and what
  belongs to the plan.

    * ABCs: `touch` and `weaning`, a list of `%{time, amount}` for tonight's night
      feeds (`amount` in minutes or ml, `nil` once a feed is dropped), from
      `Trygg.Sleep.NightWeaning`.
    * SLIP: `mode`, `visits` (tonight's first gaps in seconds, empty for a full
      plan) and `expected` crying at bedtime.
    * SWAP: `variant` and `step` (`Trygg.Sleep.Swap.tonight/3`).
  """
  def tonight(%Plan{} = plan, %Child{} = child, %DateTime{} = now) do
    night = night_number(plan, child, now)
    nights = Definitions.nights(plan)

    base = %{
      definition: plan.definition,
      night: night,
      nights: nights,
      date: night_date(plan, max(night, 1)),
      finished?: night > nights
    }

    Map.merge(base, specifics(plan, max(night, 1), night))
  end

  defp specifics(%Plan{definition: :abcs} = plan, n, night),
    do: %{touch: Abcs.touch(n), weaning: weaning(plan, night)}

  defp specifics(%Plan{definition: :slip, options: options}, n, _night) do
    mode = if options["mode"] == "full", do: :full, else: :graduated

    %{
      mode: mode,
      visits: if(mode == :graduated, do: Slip.schedule(n), else: []),
      expected: Slip.expected(n)
    }
  end

  defp specifics(%Plan{definition: :swap, options: options}, n, _night) do
    variant = Swap.variant(options["variant"])
    %{variant: variant, step: Swap.tonight(variant.id, n, options)}
  end

  @doc "The feed schedule of the plan as a table (`Trygg.Sleep.NightWeaning.generate/3`), or `nil` without night feeds."
  def weaning_table(%Plan{feed_kind: kind, feed_times: times, feed_amounts: amounts})
      when kind in [:nursing, :bottle] and times != [] do
    NightWeaning.generate(kind, Enum.zip(times, amounts))
  end

  def weaning_table(_plan), do: nil

  defp weaning(plan, night) when night >= 1 do
    case weaning_table(plan) do
      nil ->
        []

      %{rows: rows} ->
        for row <- rows, do: %{time: row.time, amount: Enum.at(row.amounts, night - 1)}
    end
  end

  defp weaning(_plan, _night), do: []

  defp child_for(%Plan{child_id: id}), do: %Child{id: id}
end
