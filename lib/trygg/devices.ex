defmodule Trygg.Devices do
  @moduledoc """
  Sensor devices that report to a family, and the readings they send.

  A device registers itself: the first reading from a `hardware_id` the family
  hasn't seen creates the device, unnamed. A caregiver then names it so the
  family knows which room it is in. Devices belong to the family, not to a
  child, and reach this module through a family API token (`Trygg.ApiTokens`),
  whose role must be `:caregiver` to report.

  Every reading is broadcast on the family's topic (`subscribe/1`) as
  `{:device_reading, device, reading}` so open screens update live; naming or
  forgetting a device sends `{:device_changed, device}` and
  `{:device_deleted, device_id}`.
  """

  import Ecto.Query, warn: false

  alias Trygg.Accounts.Scope
  alias Trygg.Devices.{Device, Reading}
  alias Trygg.Families
  alias Trygg.Repo

  # Readings older than this are dropped by `Trygg.Devices.PruneWorker`.
  @retention_days 30

  ## PubSub -------------------------------------------------------------------

  @doc "Topic string for realtime messages about a family's devices."
  def topic(family_id), do: "family_devices:#{family_id}"

  @doc "Subscribe the calling process to a family's device messages."
  def subscribe(family_id), do: Phoenix.PubSub.subscribe(Trygg.PubSub, topic(family_id))

  defp broadcast(family_id, message),
    do: Phoenix.PubSub.broadcast(Trygg.PubSub, topic(family_id), message)

  ## Devices ------------------------------------------------------------------

  @doc """
  The family's devices, oldest first, each with `:latest` set to its newest
  reading (or `nil`). Any member can look.
  """
  def list_devices(%Scope{} = scope, family_id) do
    Families.authorize_family!(scope, family_id, :viewer)

    devices = Repo.all(from d in Device, where: d.family_id == ^family_id, order_by: d.id)
    latest = latest_readings(Enum.map(devices, & &1.id))
    Enum.map(devices, &%{&1 | latest: latest[&1.id]})
  end

  defp latest_readings([]), do: %{}

  defp latest_readings(device_ids) do
    from(r in Reading,
      where: r.device_id in ^device_ids,
      distinct: r.device_id,
      order_by: [asc: r.device_id, desc: r.measured_at]
    )
    |> Repo.all()
    |> Map.new(&{&1.device_id, &1})
  end

  @doc "Fetches one of the family's devices (with `:latest`). Raises `Ecto.NoResultsError`."
  def get_device!(%Scope{} = scope, family_id, id) do
    Families.authorize_family!(scope, family_id, :viewer)
    device = Repo.get_by!(Device, id: id, family_id: family_id)
    %{device | latest: latest_readings([device.id])[device.id]}
  end

  @doc "A changeset for the rename form."
  def change_device(%Device{} = device, attrs \\ %{}), do: Device.name_changeset(device, attrs)

  @doc "Names (or renames) a device. Caregivers and owners can."
  def name_device(%Scope{} = scope, %Device{} = device, attrs) do
    Families.authorize_family!(scope, device.family_id, :caregiver)

    with {:ok, updated} <- device |> Device.name_changeset(attrs) |> Repo.update() do
      updated = %{updated | latest: device.latest}
      broadcast(updated.family_id, {:device_changed, updated})
      {:ok, updated}
    end
  end

  @doc """
  Forgets a device and its readings. If it is still running it registers again,
  unnamed, with its next reading.
  """
  def delete_device(%Scope{} = scope, %Device{} = device) do
    Families.authorize_family!(scope, device.family_id, :caregiver)

    with {:ok, device} <- Repo.delete(device) do
      broadcast(device.family_id, {:device_deleted, device.id})
      {:ok, device}
    end
  end

  ## Readings -----------------------------------------------------------------

  @doc """
  Records a reading from the device `hardware_id` in the family, registering the
  device if it is new. `attrs` takes `"temperature_c"`, `"humidity_pct"`,
  `"pressure_hpa"`, `"gas_ohms"`, an optional `"measured_at"` (defaults to now)
  and an optional `"model"` for the device.

  Returns `{:ok, %{device: device, reading: reading}}` (`device.latest` is the
  reading), or `{:error, changeset}`. Needs a caregiver-level scope.
  """
  def record_reading(%Scope{} = scope, family_id, hardware_id, attrs) do
    Families.authorize_family!(scope, family_id, :caregiver)
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    now = DateTime.utc_now()

    changeset = Reading.changeset(%Reading{}, Map.put_new(attrs, "measured_at", now))

    # Validate the sample before registering, so a bad one can't leave an empty device behind.
    with {:ok, _} <- Ecto.Changeset.apply_action(changeset, :insert),
         {:ok, device} <- register(family_id, hardware_id, attrs["model"]),
         {:ok, reading} <-
           changeset |> Ecto.Changeset.put_change(:device_id, device.id) |> Repo.insert() do
      device = touch(device, now, attrs["model"], reading)
      broadcast(family_id, {:device_reading, device, reading})
      {:ok, %{device: device, reading: reading}}
    end
  end

  # Finds the family's device or creates it unnamed. The unique index settles a race
  # between two first readings.
  defp register(family_id, hardware_id, model) do
    case Repo.get_by(Device, family_id: family_id, hardware_id: to_string(hardware_id)) do
      %Device{} = device ->
        {:ok, device}

      nil ->
        with {:ok, _} <-
               %Device{family_id: family_id}
               |> Device.registration_changeset(%{"hardware_id" => hardware_id, "model" => model})
               |> Repo.insert(on_conflict: :nothing, conflict_target: [:family_id, :hardware_id]) do
          {:ok, Repo.get_by!(Device, family_id: family_id, hardware_id: hardware_id)}
        end
    end
  end

  defp touch(device, now, model, reading) do
    seen = DateTime.truncate(now, :second)

    changes =
      [last_seen_at: seen] ++ if(is_binary(model) and model != "", do: [model: model], else: [])

    Repo.update_all(from(d in Device, where: d.id == ^device.id), set: changes)
    struct(device, Keyword.put(changes, :latest, reading))
  end

  @doc "Deletes readings older than the retention period. Returns how many went."
  def prune_readings(days \\ @retention_days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)
    {count, _} = Repo.delete_all(from r in Reading, where: r.measured_at < ^cutoff)
    count
  end
end
