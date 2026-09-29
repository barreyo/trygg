defmodule Trygg.Notices do
  @moduledoc """
  Per-caregiver dismissals of Home notices. A dismissed notice stays hidden for
  `dismiss_days/0` days, then returns if it still applies. Keys are alert ids
  (`"no-wet-diaper"`) or `"weight-check"`. Dismissing is personal UI state, so
  it never notifies other caregivers.
  """
  import Ecto.Query

  alias Trygg.Accounts.Scope
  alias Trygg.Families
  alias Trygg.Families.Child
  alias Trygg.Notices.Dismissal
  alias Trygg.Repo

  @dismiss_days 7
  @max_keys 50

  def dismiss_days, do: @dismiss_days

  @doc "The keys this caregiver has dismissed for `child` that are still hidden."
  def dismissed(%Scope{user: user} = scope, %Child{} = child, now \\ DateTime.utc_now()) do
    Families.authorize!(scope, child, :viewer)

    from(d in Dismissal,
      where: d.user_id == ^user.id and d.child_id == ^child.id and d.dismissed_until > ^now,
      select: d.key
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Hides `keys` for `@dismiss_days` days from `now`, extending any existing
  dismissal, and returns the resulting set of hidden keys.
  """
  def dismiss(%Scope{user: user} = scope, %Child{} = child, keys, now \\ DateTime.utc_now())
      when is_list(keys) do
    Families.authorize!(scope, child, :viewer)

    now = DateTime.truncate(now, :second)
    until = DateTime.add(now, @dismiss_days * 86_400, :second)

    rows =
      keys
      |> Enum.filter(&(is_binary(&1) and &1 != "" and byte_size(&1) <= 100))
      |> Enum.uniq()
      |> Enum.take(@max_keys)
      |> Enum.map(
        &%{
          user_id: user.id,
          child_id: child.id,
          key: &1,
          dismissed_until: until,
          inserted_at: now,
          updated_at: now
        }
      )

    Repo.insert_all(Dismissal, rows,
      on_conflict: {:replace, [:dismissed_until, :updated_at]},
      conflict_target: [:user_id, :child_id, :key]
    )

    dismissed(scope, child, now)
  end
end
