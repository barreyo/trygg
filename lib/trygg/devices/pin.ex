defmodule Trygg.Devices.Pin do
  @moduledoc """
  A member's choice to show a device on their own Today screen. Devices belong to
  the family, but the pin belongs to the user, so one parent can have the room
  sensor on Today without the other seeing it.
  """
  use Ecto.Schema

  schema "device_pins" do
    belongs_to :device, Trygg.Devices.Device
    belongs_to :user, Trygg.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
