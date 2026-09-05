defmodule Trygg.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :first_name, :string
    field :last_name, :string
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true
    field :unit_system, Ecto.Enum, values: [:metric, :imperial], default: :metric
    field :theme, Ecto.Enum, values: [:system, :light, :dark], default: :system
    # How often this caregiver wants a "log a weight" nudge. `nil` follows the
    # CDC well-child schedule; `0` turns reminders off; a positive integer is a
    # fixed number of days without a logged weight.
    field :weight_reminder_days, :integer

    timestamps(type: :utc_datetime)
  end

  @doc """
  A changeset for the user's app preferences (measurement units, theme,
  weight-check reminder cadence, ...).
  """
  def settings_changeset(user, attrs) do
    user
    |> cast(attrs, [:unit_system, :theme, :weight_reminder_days])
    |> validate_required([:unit_system, :theme])
    |> validate_number(:weight_reminder_days,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 365
    )
  end

  @doc """
  How this user wants weight-check reminders: `:recommended` (the CDC
  well-child schedule), `:off`, or `{:every, days}`.
  """
  def weight_reminder_setting(%__MODULE__{weight_reminder_days: nil}), do: :recommended
  def weight_reminder_setting(%__MODULE__{weight_reminder_days: 0}), do: :off
  def weight_reminder_setting(%__MODULE__{weight_reminder_days: n}) when n > 0, do: {:every, n}

  @doc """
  A changeset for registering a user: their name plus the email address they
  sign in with.
  """
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> name_changeset(attrs)
    |> email_changeset(attrs, opts)
  end

  @doc """
  A changeset for the user's name (first and last), both required. Names are
  normalized to proper capitalization on the way in.
  """
  def name_changeset(user, attrs) do
    user
    |> cast(attrs, [:first_name, :last_name])
    |> update_change(:first_name, &capitalize_name/1)
    |> update_change(:last_name, &capitalize_name/1)
    |> validate_required([:first_name, :last_name])
    |> validate_length(:first_name, max: 100)
    |> validate_length(:last_name, max: 100)
  end

  @doc ~S"""
  Normalizes a personal name for storage and display: trims, collapses inner
  whitespace, and upper-cases the first letter of every space- or
  hyphen-separated part while lower-casing the rest.

      iex> Trygg.Accounts.User.capitalize_name("  anne-marie  VAN  der berg ")
      "Anne-Marie Van Der Berg"
  """
  def capitalize_name(nil), do: nil

  def capitalize_name(name) when is_binary(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map_join(" ", fn word ->
      word
      |> String.split("-")
      |> Enum.map_join("-", &String.capitalize/1)
    end)
  end

  @doc """
  A user changeset for registering or changing the email.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, Trygg.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now)
  end
end
