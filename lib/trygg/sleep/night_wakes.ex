defmodule Trygg.Sleep.NightWakes do
  @moduledoc """
  Night mode's shared state: starting a waking, moving to the next step,
  finishing it. Every change is broadcast on the child's topic as
  `{:night_wake, :started | :advanced | :finished, wake}`, so a partner with
  night mode open sees the same step and the same countdown.

  Writes need `:caregiver`. A step change names the step it was made from, so
  two people tapping "next" at once move it on once, not twice.
  """
  import Ecto.Query

  alias Trygg.Accounts.Scope
  alias Trygg.Families
  alias Trygg.Families.Child
  alias Trygg.Repo
  alias Trygg.Sleep.{Checkins, Methods, NightWake}

  @doc "The waking in progress for `child`, or `nil`. Requires `:viewer`."
  def active(%Scope{} = scope, %Child{} = child) do
    Families.authorize!(scope, child, :viewer)

    NightWake
    |> where([w], w.child_id == ^child.id and is_nil(w.ended_at))
    |> preload(:started_by)
    |> Repo.one()
  end

  @doc """
  Starts a waking with `method` (`:cries`, `:sit_back` or `:abcs`). If one is
  already in progress it is returned unchanged, so a double tap, or both parents
  starting at once, is harmless. Requires `:caregiver`.

  For `:abcs` (check-ins, `Trygg.Sleep.Checkins`) `opts` may carry `:plan_id` and
  `:kind` (`:waking`, the default, which starts with the crying already begun, or
  `:bedtime`, the put-down, which starts with no events).
  """
  def start(%Scope{} = scope, %Child{} = child, method, opts \\ [])
      when method in [:cries, :sit_back, :abcs] do
    Families.authorize!(scope, child, :caregiver)
    now = now()
    kind = Keyword.get(opts, :kind, :waking)

    events = if method == :abcs and kind == :waking, do: [Checkins.event("cry", now)], else: []

    result =
      %NightWake{child_id: child.id, started_by_id: scope.user.id}
      |> NightWake.changeset(%{
        method: method,
        started_at: now,
        step: 0,
        step_started_at: now,
        kind: kind,
        events: events,
        plan_id: Keyword.get(opts, :plan_id)
      })
      |> Repo.insert()

    case result do
      {:ok, wake} ->
        wake = Repo.preload(wake, :started_by)
        broadcast(wake, :started)
        {:ok, wake}

      {:error, _changeset} ->
        # Someone started one first: that's the one to follow.
        {:ok, active(scope, child)}
    end
  end

  @doc """
  Records a check-in happening (`"cry"`, `"pop_in"`, `"calm"`; see
  `Trygg.Sleep.Checkins`) on a waking, given how many events the caller saw
  (`seen`): if someone else added one first, nothing is added and the current
  state comes back, so a double tap doesn't record two pop-ins.
  """
  def record(%Scope{} = scope, %NightWake{} = wake, kind, seen)
      when kind in ["cry", "pop_in", "calm"] and is_integer(seen) do
    authorize!(scope, wake)
    event = Checkins.event(kind, DateTime.utc_now())

    {count, _} =
      Repo.update_all(
        from(w in NightWake,
          where:
            w.id == ^wake.id and is_nil(w.ended_at) and
              fragment("cardinality(?) = ?", w.events, ^seen),
          update: [
            set: [
              events: fragment("array_append(?, ?)", w.events, type(^event, :map)),
              updated_at: ^now()
            ]
          ]
        ),
        []
      )

    fresh = reload(wake)
    if count == 1, do: broadcast(fresh, :advanced)
    {:ok, fresh}
  end

  @doc """
  They fell asleep: ends a check-in waking as `:settled`, recording the asleep
  time and the total time spent crying. `seen` is the number of events the
  caller saw, as for `record/4`.
  """
  def asleep(%Scope{} = scope, %NightWake{} = wake, seen) when is_integer(seen) do
    authorize!(scope, wake)
    event = Checkins.event("asleep", DateTime.utc_now())

    {fresh, changed?} =
      Repo.transact(fn ->
        {count, _} =
          Repo.update_all(
            from(w in NightWake,
              where:
                w.id == ^wake.id and is_nil(w.ended_at) and
                  fragment("cardinality(?) = ?", w.events, ^seen),
              update: [
                set: [events: fragment("array_append(?, ?)", w.events, type(^event, :map))]
              ]
            ),
            []
          )

        if count == 1,
          do: {:ok, finish_checkins(wake, :settled)},
          else: {:ok, {reload(wake), false}}
      end)
      |> then(fn {:ok, result} -> result end)

    if changed?, do: broadcast(fresh, :finished)
    {:ok, fresh}
  end

  # Ends a check-in waking, stamping the total time spent crying. Returns
  # `{wake, changed?}`: false when it had already ended.
  defp finish_checkins(wake, outcome) do
    at = now()
    cry = Checkins.state(reload(wake).events, at).cry_seconds

    {count, _} =
      Repo.update_all(
        from(w in NightWake, where: w.id == ^wake.id and is_nil(w.ended_at)),
        set: [outcome: outcome, ended_at: at, cry_seconds: cry, updated_at: at]
      )

    {reload(wake), count == 1}
  end

  @doc """
  Moves a waking on from `from_step` to the next step. A no-op returning the
  current state if it has already moved on or ended. Returns
  `{:ok, wake}`, or `{:error, :last_step}` at the end of the method.
  """
  def advance(%Scope{} = scope, %NightWake{} = wake, from_step) when is_integer(from_step) do
    authorize!(scope, wake)

    if from_step + 1 >= Methods.count(wake.method) do
      {:error, :last_step}
    else
      move_to(wake, from_step, from_step + 1)
    end
  end

  @doc "Goes back to the first step, e.g. when a feed isn't due. Same staleness rules as `advance/3`."
  def restart(%Scope{} = scope, %NightWake{} = wake, from_step) when is_integer(from_step) do
    authorize!(scope, wake)
    move_to(wake, from_step, 0)
  end

  defp move_to(wake, from_step, to_step) do
    {count, _} =
      Repo.update_all(
        from(w in NightWake,
          where: w.id == ^wake.id and w.step == ^from_step and is_nil(w.ended_at)
        ),
        set: [step: to_step, step_started_at: now(), updated_at: now()]
      )

    fresh = reload(wake)
    if count == 1, do: broadcast(fresh, :advanced)
    {:ok, fresh}
  end

  @doc """
  Ends a waking with `outcome` (`:settled`, `:fed` or `:stopped`), recording the
  step it was on. A no-op returning the ended waking if it already ended.
  """
  def finish(%Scope{} = scope, %NightWake{} = wake, outcome)
      when outcome in [:settled, :fed, :stopped] do
    authorize!(scope, wake)

    {fresh, changed?} =
      if wake.method == :abcs,
        do: finish_checkins(wake, outcome),
        else: finish_steps(wake, outcome)

    if changed?, do: broadcast(fresh, :finished)
    {:ok, fresh}
  end

  defp finish_steps(wake, outcome) do
    {count, _} =
      Repo.update_all(
        from(w in NightWake, where: w.id == ^wake.id and is_nil(w.ended_at)),
        set: [outcome: outcome, ended_at: now(), settled_step: wake.step, updated_at: now()]
      )

    {reload(wake), count == 1}
  end

  @doc """
  The wakings (finished or not) that began in the last `days` days, newest
  first. Requires `:viewer`.
  """
  def recent(%Scope{} = scope, %Child{} = child, days \\ 7) do
    Families.authorize!(scope, child, :viewer)
    since = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    NightWake
    |> where([w], w.child_id == ^child.id and w.started_at >= ^since)
    |> order_by(desc: :started_at, desc: :id)
    |> preload(:started_by)
    |> Repo.all()
  end

  @doc """
  Every waking recorded for `plan`, oldest first. Requires `:viewer`.
  """
  def for_plan(%Scope{} = scope, %Trygg.Sleep.Plan{} = plan) do
    Families.authorize!(scope, %Child{id: plan.child_id}, :viewer)

    NightWake
    |> where([w], w.plan_id == ^plan.id)
    |> order_by(asc: :started_at, asc: :id)
    |> Repo.all()
  end

  @doc """
  A summary of finished wakings: `%{count, settled, fed, stopped, settled_at}`
  where `settled_at` maps a step number to how many settled there.
  """
  def summarize(wakes) do
    finished = Enum.reject(wakes, &NightWake.active?/1)

    %{
      count: length(finished),
      settled: Enum.count(finished, &(&1.outcome == :settled)),
      fed: Enum.count(finished, &(&1.outcome == :fed)),
      stopped: Enum.count(finished, &(&1.outcome == :stopped)),
      settled_at:
        finished
        |> Enum.filter(&(&1.outcome == :settled))
        |> Enum.frequencies_by(& &1.settled_step)
    }
  end

  @doc "Seconds left in the current step at `now`, `nil` for an untimed step."
  def seconds_left(%NightWake{} = wake, %DateTime{} = now) do
    case Methods.step(wake.method, wake.step) do
      %{seconds: seconds} when is_integer(seconds) ->
        DateTime.diff(DateTime.add(wake.step_started_at, seconds, :second), now, :second)

      _ ->
        nil
    end
  end

  defp authorize!(scope, %NightWake{child_id: child_id}),
    do: Families.authorize!(scope, %Child{id: child_id}, :caregiver)

  defp reload(wake), do: NightWake |> Repo.get!(wake.id) |> Repo.preload(:started_by)

  defp broadcast(wake, action),
    do: Families.broadcast(wake.child_id, {:night_wake, action, wake})

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
