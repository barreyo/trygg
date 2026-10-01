defmodule Trygg.Families.Membership do
  use Ecto.Schema
  import Ecto.Changeset

  @roles [:owner, :caregiver, :viewer]

  schema "memberships" do
    field :role, Ecto.Enum, values: @roles, default: :caregiver

    belongs_to :family, Trygg.Families.Family
    belongs_to :user, Trygg.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role])
    |> validate_required([:role])
    |> unique_constraint([:family_id, :user_id])
  end

  def roles, do: @roles
end
