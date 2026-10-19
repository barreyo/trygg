defmodule Trygg.Devices do
  @moduledoc """
  Sensor devices that report to a family, and the readings they send.

  A device registers itself: the first reading from a `hardware_id` the family
  hasn't seen creates the device, unnamed, with a random five-digit `short_id`
  that the device shows on its own screen. A caregiver then names it so the
  family knows which room it is in, and can pin it to the Today screen. Devices belong to the family, not to a
  child, and reach this module through a family API token (`Trygg.ApiTokens`),
  whose role must be `:caregiver` to report.

  Every reading is broadcast on the family's topic (`subscribe/1`) as
  `{:device_reading, device, reading}` so open screens update live; naming or
  forgetting a device sends `{:device_changed, device}` and
  `{:device_deleted, device_id}`. Pinning a device to Today (`set_on_today/3`) is
  a `{:device_changed, device}` too.
  """

  import Ecto.Query, warn: false

  alias Trygg.Accounts.Scope
  alias Trygg.Devices.{Device, Reading}
  alias Trygg.Families
  alias Trygg.Repo

  # Readings older than this are dropped by `Trygg.Devices.PruneWorker`.
  @retention_days 30

  # The windows the detail page can graph, as `{param, label, seconds}`, and how many
  # points a graph is thinned to: a day of 30 s samples is 2,880 of them, far more than
  # a phone screen can show.
  @history_ranges [
    {"6h", "6 hours", 6 * 3600},
    {"24h", "24 hours", 24 * 3600},
    {"7d", "7 days", 7 * 86_400},
    {"30d", "30 days", 30 * 86_400}
  ]
  @history_points 120

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

  @doc "The graphable windows as `{param, label, seconds}`, shortest first."
  def history_ranges, do: @history_ranges

  @doc """
  The device's readings over the last `seconds`, thinned to about #{@history_points}
  points by averaging each time bucket. Returns `%{points: [point], bucket: seconds,
  from: DateTime, to: DateTime}`, oldest point first; a point is `%{at: DateTime,
  temperature_c:, humidity_pct:, pressure_hpa:, gas_ohms:}` (a field is `nil` when
  nothing in the bucket reported it). Any member can look.
  """
  def history(%Scope{} = scope, %Device{} = device, seconds) when seconds > 0 do
    Families.authorize_family!(scope, device.family_id, :viewer)

    to = DateTime.utc_now()
    from = DateTime.add(to, -seconds, :second)
    bucket = max(div(seconds, @history_points), 30)

    points =
      from(r in Reading,
        where: r.device_id == ^device.id and r.measured_at >= ^from,
        group_by: selected_as(:bucket),
        order_by: selected_as(:bucket),
        select: %{
          bucket:
            selected_as(
              fragment(
                "floor(extract(epoch from ?) / ?::integer)::bigint * ?::integer",
                r.measured_at,
                ^bucket,
                ^bucket
              ),
              :bucket
            ),
          temperature_c: type(avg(r.temperature_c), :float),
          humidity_pct: type(avg(r.humidity_pct), :float),
          pressure_hpa: type(avg(r.pressure_hpa), :float),
          gas_ohms: type(avg(r.gas_ohms), :float)
        }
      )
      |> Repo.all()
      |> Enum.map(fn %{bucket: unix} = point ->
        point |> Map.delete(:bucket) |> Map.put(:at, DateTime.from_unix!(unix))
      end)

    %{points: points, bucket: bucket, from: from, to: to}
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
  Pins the family's devices in `ids` to the Today screen and unpins the rest.
  Caregivers and owners can. Returns the devices that changed.
  """
  def set_today_devices(%Scope{} = scope, family_id, ids) do
    Families.authorize_family!(scope, family_id, :caregiver)
    ids = MapSet.new(ids, &to_string/1)

    devices = Repo.all(from d in Device, where: d.family_id == ^family_id, order_by: d.id)
    latest = latest_readings(Enum.map(devices, & &1.id))

    for device <- devices,
        wanted <- [MapSet.member?(ids, to_string(device.id))],
        wanted != device.on_today do
      {1, _} =
        Repo.update_all(from(d in Device, where: d.id == ^device.id), set: [on_today: wanted])

      updated = %{device | on_today: wanted, latest: latest[device.id]}
      broadcast(family_id, {:device_changed, updated})
      updated
    end
  end

  @doc "Pins one device to the Today screen, or unpins it. Caregivers and owners can."
  def set_on_today(%Scope{} = scope, %Device{} = device, on_today) when is_boolean(on_today) do
    Families.authorize_family!(scope, device.family_id, :caregiver)

    {1, _} =
      Repo.update_all(from(d in Device, where: d.id == ^device.id), set: [on_today: on_today])

    updated = %{device | on_today: on_today}
    broadcast(updated.family_id, {:device_changed, updated})
    {:ok, updated}
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
  defp register(family_id, hardware_id, model, attempts \\ 5) do
    case Repo.get_by(Device, family_id: family_id, hardware_id: to_string(hardware_id)) do
      %Device{} = device ->
        {:ok, device}

      nil ->
        result =
          %Device{family_id: family_id}
          |> Device.registration_changeset(%{"hardware_id" => hardware_id, "model" => model})
          |> Repo.insert(on_conflict: :nothing, conflict_target: [:family_id, :hardware_id])

        case result do
          {:ok, _} ->
            {:ok, Repo.get_by!(Device, family_id: family_id, hardware_id: hardware_id)}

          # The random short id is already taken in this family: draw another.
          {:error, %Ecto.Changeset{errors: [{:short_id, _} | _]}} when attempts > 1 ->
            register(family_id, hardware_id, model, attempts - 1)

          error ->
            error
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
