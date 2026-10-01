defmodule Trygg.Families.Family do
  @moduledoc """
  The group of caregivers that shares one or more children.

  Membership (and so every role) is held by the family, not by a child: a
  caregiver of a family sees all of its children. A family has no name of its
  own — `label/1` describes it by the children in it.
  """
  use Ecto.Schema

  schema "families" do
    has_many :children, Trygg.Families.Child
    has_many :memberships, Trygg.Families.Membership
    has_many :invites, Trygg.Families.Invite
    has_many :api_tokens, Trygg.Families.ApiToken

    timestamps(type: :utc_datetime)
  end

  @doc """
  A human label built from the family's children ("Alma", "Alma & Otto",
  "Alma, Otto & Ines"). Expects `:children` to be preloaded.
  """
  def label(%__MODULE__{children: children}) do
    case children |> Enum.sort_by(& &1.inserted_at, DateTime) |> Enum.map(& &1.name) do
      [] -> "Empty family"
      [name] -> name
      names -> Enum.join(Enum.drop(names, -1), ", ") <> " & " <> List.last(names)
    end
  end
end
