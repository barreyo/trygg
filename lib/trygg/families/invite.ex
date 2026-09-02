defmodule Trygg.Families.Invite do
  use Ecto.Schema
  import Ecto.Changeset

  @roles [:caregiver, :viewer]
  @valid_for_days 14

  schema "invites" do
    field :email, :string
    field :role, Ecto.Enum, values: @roles, default: :caregiver
    field :token, :string
    field :accepted_at, :utc_datetime
    field :expires_at, :utc_datetime

    belongs_to :child, Trygg.Families.Child
    belongs_to :invited_by, Trygg.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(invite, attrs) do
    invite
    |> cast(attrs, [:email, :role])
    |> update_change(:email, fn email -> email |> String.trim() |> String.downcase() end)
    |> validate_required([:email, :role])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/, message: "must be a valid email")
    |> validate_length(:email, max: 160)
    |> put_token()
    |> put_expiry()
    |> unique_constraint(:token)
  end

  defp put_token(changeset) do
    if get_field(changeset, :token) do
      changeset
    else
      put_change(
        changeset,
        :token,
        Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
      )
    end
  end

  defp put_expiry(changeset) do
    if get_field(changeset, :expires_at) do
      changeset
    else
      expires_at =
        DateTime.utc_now() |> DateTime.add(@valid_for_days, :day) |> DateTime.truncate(:second)

      put_change(changeset, :expires_at, expires_at)
    end
  end

  @doc "Whether the invite is still open (not accepted and not expired)."
  def pending?(%__MODULE__{accepted_at: nil, expires_at: expires_at}) do
    DateTime.after?(expires_at, DateTime.utc_now())
  end

  def pending?(%__MODULE__{}), do: false

  def roles, do: @roles
end
