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
  alias Trygg.Sleep.{Methods, NightWake}

  @doc "The waking in progress for `child`, or `nil`. Requires `:viewer`."
  def active(%Scope{} = scope, %Child{} = child) do
    Families.authorize!(scope, child, :viewer)

    NightWake
    |> where([w], w.child_id == ^child.id and is_nil(w.ended_at))
    |> preload(:started_by)
    |> Repo.one()
  end

  @doc """
  Starts a waking with `method` (`:cries` or `:sit_back`). If one is already in
  progress it is returned unchanged, so a double tap, or both parents starting
  at once, is harmless. Requires `:caregiver`.
  """
  def start(%Scope{} = scope, %Child{} = child, method) when method in [:cries, :sit_back] do
    Families.authorize!(scope, child, :caregiver)
    now = now()

    result =
      %NightWake{child_id: child.id, started_by_id: scope.user.id}
      |> NightWake.changeset(%{method: method, started_at: now, step: 0, step_started_at: now})
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

    {count, _} =
      Repo.update_all(
        from(w in NightWake, where: w.id == ^wake.id and is_nil(w.ended_at)),
        set: [outcome: outcome, ended_at: now(), settled_step: wake.step, updated_at: now()]
      )

    fresh = reload(wake)
    if count == 1, do: broadcast(fresh, :finished)
    {:ok, fresh}
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
    |> order_by(desc: :started_at)
    |> preload(:started_by)
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
