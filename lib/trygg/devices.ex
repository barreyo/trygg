defmodule Trygg.Devices do
  @moduledoc """
  Sensor devices that report to a family, and the readings they send.

  A device registers itself: the first reading from a `hardware_id` the family
  hasn't seen creates the device, unnamed, with a random five-digit `short_id`
  that the device shows on its own screen. A caregiver then names it so the
  family knows which room it is in. Devices belong to the family, not to a
  child, and reach this module through a family API token (`Trygg.ApiTokens`),
  whose role must be `:caregiver` to report.

  Every reading is broadcast on the family's topic (`subscribe/1`) as
  `{:device_reading, device, reading}` so open screens update live; naming or
  forgetting a device sends `{:device_changed, device}` and
  `{:device_deleted, device_id}`.

  Any member can pin a device to their own Today screen (`set_on_today/3`,
  `set_today_devices/3`). The pin is personal: it is stored per user, so it is not
  broadcast and the rest of the family's Today screens are unchanged.
  """

  import Ecto.Query, warn: false

  alias Trygg.Accounts.Scope
  alias Trygg.Devices.{AirBaseline, Device, Pin, Reading}
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
  reading (or `nil`). Any member can look. Devices the user has pinned to Today
  also carry their `:air_alert`.
  """
  def list_devices(%Scope{} = scope, family_id) do
    Families.authorize_family!(scope, family_id, :viewer)

    devices = Repo.all(from d in Device, where: d.family_id == ^family_id, order_by: d.id)
    latest = latest_readings(Enum.map(devices, & &1.id))
    pinned = pinned_ids(scope, family_id)

    Enum.map(devices, fn device ->
      device = %{device | latest: latest[device.id]}
      if MapSet.member?(pinned, device.id), do: with_air_alert(device), else: device
    end)
  end

  @doc """
  The ids of the family's devices the user has pinned to their own Today screen.
  Any member can look.
  """
  def pinned_ids(%Scope{user: user} = scope, family_id) do
    Families.authorize_family!(scope, family_id, :viewer)

    from(p in Pin,
      join: d in assoc(p, :device),
      where: p.user_id == ^user.id and d.family_id == ^family_id,
      select: p.device_id
    )
    |> Repo.all()
    |> MapSet.new()
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
    with_air_alert(%{device | latest: latest_readings([device.id])[device.id]})
  end

  @doc "The graphable windows as `{param, label, seconds}`, shortest first."
  def history_ranges, do: @history_ranges

  @doc """
  The device's readings over the last `seconds`, thinned to about #{@history_points}
  points by averaging each time bucket. Returns `%{points: [point], bucket: seconds,
  from: DateTime, to: DateTime}`, oldest point first; a point is `%{at: DateTime,
  temperature_c:, humidity_pct:, pressure_hpa:, gas_ohms:, iaq:, co2_ppm:, voc_ppm:}`
  (a field is `nil` when nothing in the bucket reported it). The air quality fields
  average only the readings BSEC had begun to trust (accuracy 1 or more), since its
  first minutes are a placeholder value. Any member can look.
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
          gas_ohms: type(avg(r.gas_ohms), :float),
          iaq: type(filter(avg(r.iaq), r.iaq_accuracy >= 1), :float),
          co2_ppm: type(filter(avg(r.co2_ppm), r.iaq_accuracy >= 1), :float),
          voc_ppm: type(filter(avg(r.voc_ppm), r.iaq_accuracy >= 1), :float)
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
  Pins the family's devices in `ids` to the user's own Today screen and unpins the
  rest. Any member can: it changes only their Today. Returns the devices that changed.
  """
  def set_today_devices(%Scope{user: user} = scope, family_id, ids) do
    Families.authorize_family!(scope, family_id, :viewer)
    ids = MapSet.new(ids, &to_string/1)
    pinned = pinned_ids(scope, family_id)

    devices = Repo.all(from d in Device, where: d.family_id == ^family_id, order_by: d.id)
    latest = latest_readings(Enum.map(devices, & &1.id))

    for device <- devices,
        wanted <- [MapSet.member?(ids, to_string(device.id))],
        wanted != MapSet.member?(pinned, device.id) do
      write_pin(user, device, wanted)
      device = %{device | latest: latest[device.id]}
      if wanted, do: with_air_alert(device), else: device
    end
  end

  @doc """
  Pins one device to the user's own Today screen, or unpins it. Any member can; it
  changes only their Today.
  """
  def set_on_today(%Scope{user: user} = scope, %Device{} = device, on_today)
      when is_boolean(on_today) do
    Families.authorize_family!(scope, device.family_id, :viewer)

    write_pin(user, device, on_today)
    {:ok, if(on_today, do: with_air_alert(device), else: %{device | air_alert: nil})}
  end

  defp write_pin(user, device, true) do
    Repo.insert!(%Pin{user_id: user.id, device_id: device.id},
      on_conflict: :nothing,
      conflict_target: [:user_id, :device_id]
    )
  end

  defp write_pin(user, device, false) do
    Repo.delete_all(from p in Pin, where: p.user_id == ^user.id and p.device_id == ^device.id)
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
  `"pressure_hpa"`, `"gas_ohms"`, `"iaq"`, `"iaq_accuracy"`, `"co2_ppm"`,
  `"voc_ppm"`, an optional `"measured_at"` (defaults to now)
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
    device |> struct(Keyword.put(changes, :latest, reading)) |> with_air_alert()
  end

  defp with_air_alert(%Device{} = device),
    do: %{device | air_alert: AirBaseline.alert(device.id)}

  @doc "Deletes readings older than the retention period. Returns how many went."
  def prune_readings(days \\ @retention_days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)
    {count, _} = Repo.delete_all(from r in Reading, where: r.measured_at < ^cutoff)
    count
  end
end
