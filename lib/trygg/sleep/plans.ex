defmodule Trygg.Sleep.Plans do
  @moduledoc """
  Starting, following and ending a sleep-training plan
  (`Trygg.Sleep.Plan`, "The ABCs of Sleep").

  A plan only opens when all of these hold, and `eligibility/3` says which don't:
  the child is at least 5 months old (corrected), a caregiver has recorded that
  the pediatrician is fine with sleep training
  (`children.sleep_training_cleared_on`), and every item of the pre-flight
  checklist (`Trygg.Sleep.Abcs.preflight/0`) has been ticked.

  Writes need `:caregiver`; reads `:viewer`.
  """
  import Ecto.Query

  alias Trygg.Accounts.Scope
  alias Trygg.Families
  alias Trygg.Families.Child
  alias Trygg.Repo
  alias Trygg.Sleep.{Abcs, NightWeaning, Plan}

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
  What stands between this child and starting: `%{age, clearance, preflight,
  ready?}`.

    * `age` — `{:ok, nil}` or `{:locked, unlock_date}` (nil without a birth date).
    * `clearance` — the date the pediatrician's go-ahead was recorded, or `nil`.
    * `preflight` — `%{done, total, missing}` over the pre-flight checklist.
  """
  def eligibility(%Child{} = child, phase, %Date{} = today) do
    age =
      case phase do
        %{age_days: days} when days >= 0 ->
          if days >= Abcs.min_age_days(),
            do: {:ok, nil},
            else: {:locked, Date.add(today, Abcs.min_age_days() - days)}

        _ ->
          {:locked, nil}
      end

    ticks = child.sleep_checks || %{}
    ids = Abcs.preflight_ids()
    missing = Enum.reject(ids, &Map.has_key?(ticks, &1))

    %{
      age: age,
      clearance: child.sleep_training_cleared_on,
      preflight: %{done: length(ids) - length(missing), total: length(ids), missing: missing},
      ready?:
        match?({:ok, _}, age) and not is_nil(child.sleep_training_cleared_on) and missing == []
    }
  end

  @doc """
  Starts "The ABCs of Sleep" for `child`, night 1 being the evening of
  `attrs[:started_on]` (default: today). `attrs` may carry the night-weaning setup
  (`:feed_kind`, `:feed_times`, `:feed_amounts`). Returns `{:error, :not_ready}`
  unless `eligibility/3` says `ready?`, and `{:error, :already_active}` if a
  plan is already running.
  """
  def start(%Scope{} = scope, %Child{} = child, phase, attrs \\ %{}) do
    Families.authorize!(scope, child, :caregiver)
    today = Child.local_today(child)

    if eligibility(child, phase, today).ready? do
      attrs =
        attrs
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.put_new("started_on", today)
        |> Map.put("definition", "abcs")
        |> Map.put("status", "active")

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

  @doc "Ends a plan as `:completed` or `:stopped` today. Requires `:caregiver`."
  def finish(%Scope{} = scope, %Plan{} = plan, status) when status in [:completed, :stopped] do
    child = child_for(plan)
    Families.authorize!(scope, child, :caregiver)

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
  What to do tonight: `%{night, nights, date, touch, weaning, finished?}`. `weaning`
  is a list of `%{time, amount}` for tonight's night feeds (`amount` in minutes or
  ml, `nil` once a feed is dropped), from `Trygg.Sleep.NightWeaning`.
  """
  def tonight(%Plan{} = plan, %Child{} = child, %DateTime{} = now) do
    night = night_number(plan, child, now)
    nights = Abcs.nights()

    %{
      night: night,
      nights: nights,
      date: night_date(plan, max(night, 1)),
      touch: Abcs.touch(max(night, 1)),
      weaning: weaning(plan, night),
      finished?: night > nights
    }
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
