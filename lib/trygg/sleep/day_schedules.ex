defmodule Trygg.Sleep.DaySchedules do
  @moduledoc """
  The sleep day a family has chosen (`Trygg.Sleep.DaySchedule`), laid over the
  guide for their child's age.

  Each field of the day has one value and a `source`, in this order:

    1. `:pinned`: set by a caregiver; it always wins.
    2. `:observed`: what the log shows they usually do (wake-up and bedtime
       only, and only where the guide has no clock time of its own).
    3. `:guide`: the table for their corrected age (`Trygg.Sleep.Schedules`
       from 13 weeks, `Trygg.Sleep.AgeGuide` before), which moves up by itself
       as they grow.

  Before 13 weeks there are no nap times to follow: the day is a wake-up and
  evening anchor plus the age's usual wake window, so `effective/4` returns
  `mode: :newborn` with those and no `day`.

  Reads need `:viewer`, writes `:caregiver`.
  """
  import Ecto.Query

  alias Trygg.Accounts.Scope
  alias Trygg.Families
  alias Trygg.Families.Child
  alias Trygg.Repo
  alias Trygg.Sleep.{AgeGuide, DaySchedule, Phase, Schedules}

  @default_wake 7 * 60

  @doc "The child's saved schedule, or `nil` when they follow the guide as it is. Requires `:viewer`."
  def get(%Scope{} = scope, %Child{} = child) do
    Families.authorize!(scope, child, :viewer)
    fetch(child)
  end

  @doc """
  Saves `attrs` (see `parse_params/1`) as the child's schedule, replacing what
  was there. Saving nothing but blanks removes it. Slots beyond `nap_count` are
  dropped. Returns `{:ok, schedule | nil}` or `{:error, changeset}`. Requires
  `:caregiver`.
  """
  def save(%Scope{} = scope, %Child{} = child, attrs) do
    Families.authorize!(scope, child, :caregiver)
    guide_id = guide_id(Phase.for_child(child))

    # Saving replaces: what `attrs` leaves out goes back to the guide.
    attrs =
      %{
        wake_minutes: nil,
        bedtime_minutes: nil,
        nap_count: nil,
        wake_windows: [],
        nap_lengths: []
      }
      |> Map.merge(attrs)
      |> trim_slots()
      |> Map.put(:guide_id, guide_id)

    changeset =
      (fetch(child) || %DaySchedule{child_id: child.id})
      |> DaySchedule.changeset(attrs)
      |> Ecto.Changeset.put_change(:updated_by_id, scope.user.id)

    cond do
      not changeset.valid? ->
        {:error, %{changeset | action: :validate}}

      DaySchedule.empty?(Ecto.Changeset.apply_changes(changeset)) ->
        clear(scope, child)

      true ->
        with {:ok, schedule} <- Repo.insert_or_update(changeset) do
          Families.broadcast(child.id, {:day_schedule, :saved, schedule})
          {:ok, schedule}
        end
    end
  end

  @doc "Drops the child's choices so the day follows the guide again. Requires `:caregiver`."
  def clear(%Scope{} = scope, %Child{} = child) do
    Families.authorize!(scope, child, :caregiver)
    Repo.delete_all(from s in DaySchedule, where: s.child_id == ^child.id)
    Families.broadcast(child.id, {:day_schedule, :cleared, nil})
    {:ok, nil}
  end

  @doc """
  Records that the family has looked at the guide for the child's current age
  and kept their choices, so `effective/4` stops saying the guide has moved on.
  """
  def acknowledge(%Scope{} = scope, %Child{} = child) do
    Families.authorize!(scope, child, :caregiver)

    case fetch(child) do
      nil ->
        {:ok, nil}

      schedule ->
        id = guide_id(Phase.for_child(child))

        with {:ok, schedule} <- schedule |> Ecto.Changeset.change(guide_id: id) |> Repo.update() do
          Families.broadcast(child.id, {:day_schedule, :saved, schedule})
          {:ok, schedule}
        end
    end
  end

  defp fetch(%Child{id: id}), do: Repo.one(from s in DaySchedule, where: s.child_id == ^id)

  @doc """
  Which guide a `phase` is on: the `Schedules` table's id from 13 weeks, else the
  `AgeGuide` band's, or `nil` without an age.
  """
  def guide_id(%{age_days: age_days}) do
    case Schedules.for_age(age_days) || AgeGuide.band(age_days) do
      nil -> nil
      %{id: id} -> Atom.to_string(id)
    end
  end

  def guide_id(_), do: nil

  @doc """
  The day for `child` in `phase`, as `schedule` (a `DaySchedule` or `nil`) laid
  over the guide. `inputs` is what the log says (all optional):
  `:today_wake` (`DateTime` of this morning's wake-up), `:observed_wake` and
  `:observed_bed` (usual times, minutes after midnight).

  Returns `nil` without an age, else

      %{mode, label, guide_id, stale?, customized?, wake, bedtime, anchor,
        wake_at, nap_count, slots, day, table, newborn}

  where `wake` and `bedtime` are `%{minutes, source}` (`bedtime` is `nil` when
  nothing is known), `anchor` says whether `day` was built from `:today`'s
  wake-up or the `:target` one (`wake_at` is the wake-up it used), and `stale?` is true when the guide has moved on
  to a new age since the schedule was saved. `nap_count`, `slots` (one
  `%{ordinal, window, nap}` per nap, each `%{minutes, source, guide}`), `day`
  (`Trygg.Sleep.Schedules.plan_day/4`) and `table` (the guide table with the
  family's choices applied) are for `mode: :guide` only; `newborn` (the
  age's `%{wake_window, naps, nap}` ranges) for `mode: :newborn` only.
  """
  def effective(child, phase, schedule, inputs \\ %{})

  def effective(_child, nil, _schedule, _inputs), do: nil

  def effective(%Child{} = child, %{age_days: age_days} = phase, schedule, inputs) do
    pins = schedule || %DaySchedule{}
    id = guide_id(phase)

    wake =
      cond do
        pins.wake_minutes -> %{minutes: pins.wake_minutes, source: :pinned}
        inputs[:observed_wake] -> %{minutes: inputs[:observed_wake], source: :observed}
        true -> %{minutes: @default_wake, source: :guide}
      end

    base = %{
      guide_id: id,
      stale?: not is_nil(pins.guide_id) and pins.guide_id != id,
      customized?: not is_nil(schedule),
      wake: wake
    }

    case Schedules.for_age(age_days) do
      nil -> newborn(base, age_days, pins, inputs)
      table -> guide(base, child, table, pins, inputs)
    end
  end

  defp newborn(base, age_days, pins, inputs) do
    band = AgeGuide.band(age_days)
    row = AgeGuide.wake_time(age_days)

    bedtime =
      cond do
        pins.bedtime_minutes -> %{minutes: pins.bedtime_minutes, source: :pinned}
        inputs[:observed_bed] -> %{minutes: inputs[:observed_bed], source: :observed}
        true -> nil
      end

    Map.merge(base, %{
      mode: :newborn,
      label: band && band.label,
      bedtime: bedtime,
      anchor: :target,
      wake_at: nil,
      nap_count: nil,
      slots: [],
      day: nil,
      table: nil,
      newborn: %{wake_window: row && row.wake, naps: band && band.naps, nap: band && band.nap}
    })
  end

  defp guide(base, child, table, pins, inputs) do
    count = pins.nap_count || length(table.windows)

    slots =
      for i <- 0..(count - 1) do
        %{
          ordinal: i + 1,
          window: slot(pins.wake_windows, table.windows, i),
          nap: slot(pins.nap_lengths, table.nap_minutes, i)
        }
      end

    eff_table = %{
      table
      | windows: Enum.map(slots, & &1.window.minutes),
        nap_minutes: Enum.map(slots, & &1.nap.minutes),
        naps: if(pins.nap_count, do: Integer.to_string(count), else: table.naps)
    }

    {wake_at, anchor} =
      case inputs[:today_wake] do
        %DateTime{} = at ->
          {at, :today}

        _ ->
          time = Time.new!(div(base.wake.minutes, 60), rem(base.wake.minutes, 60), 0)
          {Child.at_local(child, Child.local_today(child), time), :target}
      end

    day = Schedules.plan_day(child, eff_table, wake_at, bedtime: pins.bedtime_minutes)

    bedtime =
      if pins.bedtime_minutes,
        do: %{minutes: pins.bedtime_minutes, source: :pinned},
        else: %{minutes: Schedules.local_minutes(child, day.bedtime), source: :guide}

    Map.merge(base, %{
      mode: :guide,
      label: table.label,
      bedtime: bedtime,
      anchor: anchor,
      wake_at: wake_at,
      nap_count: %{
        value: count,
        source: if(pins.nap_count, do: :pinned, else: :guide),
        guide: length(table.windows)
      },
      slots: slots,
      day: day,
      table: eff_table,
      newborn: nil
    })
  end

  # The pinned value for slot `i`, else the guide's (the last one for slots the
  # guide has no entry for, when a day is given more naps than the table has).
  defp slot(pinned, guide, i) do
    guide_value = Enum.at(guide, i) || List.last(guide)

    case Enum.at(pinned, i) do
      nil -> %{minutes: guide_value, source: :guide, guide: guide_value}
      value -> %{minutes: value, source: :pinned, guide: guide_value}
    end
  end

  @doc """
  Attributes for `save/3` from the schedule form's params: `"wake"` and
  `"bedtime"` (`"HH:MM"`), `"naps"`, and `"windows"` and `"lengths"` (maps of
  slot number to minutes). Blanks and anything unreadable become `nil`, which
  means "follow the guide".
  """
  def parse_params(params) when is_map(params) do
    %{
      wake_minutes: clock(params["wake"]),
      bedtime_minutes: clock(params["bedtime"]),
      nap_count: integer(params["naps"]),
      wake_windows: slots(params["windows"]),
      nap_lengths: slots(params["lengths"])
    }
  end

  defp clock(value) when is_binary(value) do
    case Time.from_iso8601(value <> ":00") do
      {:ok, time} -> time.hour * 60 + time.minute
      _ -> nil
    end
  end

  defp clock(_), do: nil

  defp integer(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp slots(%{} = map) do
    map
    |> Enum.flat_map(fn {key, value} ->
      case integer(key) do
        i when is_integer(i) and i >= 0 -> [{i, integer(value)}]
        _ -> []
      end
    end)
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
    |> trim_trailing_nils()
  end

  defp slots(_), do: []

  defp trim_slots(attrs) do
    count = attrs[:nap_count]

    attrs
    |> Map.update(:wake_windows, [], &trim(&1, count))
    |> Map.update(:nap_lengths, [], &trim(&1, count))
  end

  defp trim(list, nil), do: trim_trailing_nils(list)
  defp trim(list, count), do: list |> Enum.take(count) |> trim_trailing_nils()

  defp trim_trailing_nils(list),
    do: list |> Enum.reverse() |> Enum.drop_while(&is_nil/1) |> Enum.reverse()
end
