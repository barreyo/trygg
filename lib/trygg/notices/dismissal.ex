defmodule Trygg.Notices.Dismissal do
  @moduledoc """
  A caregiver's dismissal of one Home notice (a health alert or the
  weight-check banner) for one child, hidden until `dismissed_until`.
  Stored server-side so it follows the user across browsers and the installed
  PWA, whose local storage is separate from the browser's.
  """
  use Ecto.Schema

  schema "notice_dismissals" do
    field :key, :string
    field :dismissed_until, :utc_datetime

    belongs_to :user, Trygg.Accounts.User
    belongs_to :child, Trygg.Families.Child

    timestamps(type: :utc_datetime)
  end
end
