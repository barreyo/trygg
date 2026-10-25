defmodule Trygg.Families.Membership do
  use Ecto.Schema
  import Ecto.Changeset

  @roles [:owner, :caregiver, :simple, :viewer]

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

  @doc """
  How a role reads to people. `:simple` is a caregiver who only gets the
  stripped-down Today screen, so it goes by the name of that mode.
  """
  def label(:simple), do: "simple mode"
  def label(role), do: to_string(role)
end
