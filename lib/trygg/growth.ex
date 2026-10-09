defmodule Trygg.Growth do
  @moduledoc """
  Height and weight measurements for a child.

  Reads require the `:viewer` role; writes require `:caregiver`. All writes
  broadcast `{:growth, :created | :updated | :deleted, measurement}` on the
  child's `Trygg.Families` topic.
  """

  import Ecto.Query, warn: false

  alias Trygg.Repo
  alias Trygg.Accounts.Scope
  alias Trygg.Families
  alias Trygg.Families.Child
  alias Trygg.Growth.CheckReminder
  alias Trygg.Growth.Measurement

  @doc """
  Lists a child's measurements, newest first, with `:logged_by` preloaded.
  """
  def list_measurements(%Scope{} = scope, %Child{} = child) do
    Families.authorize!(scope, child, :viewer)

    Measurement
    |> where(child_id: ^child.id)
    |> order_by(desc: :measured_at, desc: :id)
    |> preload(:logged_by)
    |> Repo.all()
  end

  @doc "The most recent measurement that includes a weight."
  def latest_weight(%Scope{} = scope, %Child{} = child) do
    latest_with(scope, child, :weight_g)
  end

  @doc """
  Weight-gain analysis (`Trygg.Growth.Velocity.summarize/2`) over all of the
  child's measurements. Requires `:viewer`.
  """
  def velocity(%Scope{} = scope, %Child{} = child) do
    Trygg.Growth.Velocity.summarize(child, list_measurements(scope, child))
  end

  @doc """
  The child's weight-check status for the current user, honouring their
  `weight_reminder_days` preference (CDC well-child schedule by default, a
  fixed cadence, or off). Returns the `Trygg.Growth.CheckReminder` status map
  when a check is currently due, otherwise `nil`. Requires `:viewer`.
  """
  def weight_check_reminder(%Scope{} = scope, %Child{} = child, today \\ nil) do
    Families.authorize!(scope, child, :viewer)

    case Trygg.Accounts.User.weight_reminder_setting(scope.user) do
      :off ->
        nil

      setting ->
        today = today || Child.local_today(child)

        {interval, source} =
          if match?({:every, _}, setting),
            do: {elem(setting, 1), :custom},
            else: {nil, :recommended}

        case CheckReminder.evaluate(child, latest_weight(scope, child), today, interval) do
          %{due?: true} = status -> Map.put(status, :source, source)
          _ -> nil
        end
    end
  end

  @doc "The most recent measurement that includes a height."
  def latest_height(%Scope{} = scope, %Child{} = child) do
    latest_with(scope, child, :height_cm)
  end

  defp latest_with(%Scope{} = scope, %Child{} = child, field) do
    Families.authorize!(scope, child, :viewer)

    Measurement
    |> where([m], m.child_id == ^child.id and not is_nil(field(m, ^field)))
    |> order_by(desc: :measured_at, desc: :id)
    |> limit(1)
    |> preload(:logged_by)
    |> Repo.one()
  end

  @doc "Fetches one measurement, authorizing the caller as a viewer of its child."
  def get_measurement!(%Scope{} = scope, id) do
    measurement = Measurement |> Repo.get!(id) |> Repo.preload(:logged_by)
    Families.authorize!(scope, %Child{id: measurement.child_id}, :viewer)
    measurement
  end

  @doc "Returns an `%Ecto.Changeset{}` for a measurement form."
  def change_measurement(%Measurement{} = measurement, attrs \\ %{}) do
    Measurement.changeset(measurement, attrs)
  end

  @doc """
  Records a measurement for the child. Requires `:caregiver`.

  `attrs` may include `"measured_at"` (a `DateTime`) or `"measured_on"` (a
  `Date` or ISO date string in the child's time zone). Missing dates default
  to the child's local today. `weight_g` and `height_cm` are canonical metric
  storage units; at least one is required.
  """
  def create_measurement(%Scope{} = scope, %Child{} = child, attrs \\ %{}) do
    Families.authorize!(scope, child, :caregiver)

    attrs =
      attrs
      |> stringify()
      |> put_measured_at(child, default: true)

    %Measurement{child_id: child.id, logged_by_id: scope.user.id}
    |> Measurement.changeset(attrs)
    |> Repo.insert()
    |> broadcast(child.id, :created)
  end

  @doc "Updates a measurement. Requires `:caregiver` for the measurement's child."
  def update_measurement(%Scope{} = scope, %Measurement{} = measurement, attrs) do
    Families.authorize!(scope, %Child{id: measurement.child_id}, :caregiver)
    child = Repo.get!(Child, measurement.child_id)

    attrs =
      attrs
      |> stringify()
      |> put_measured_at(child, default: false)

    measurement
    |> Measurement.changeset(attrs)
    |> Repo.update()
    |> broadcast(measurement.child_id, :updated)
  end

  @doc "Deletes a measurement. Requires `:caregiver` for the measurement's child."
  def delete_measurement(%Scope{} = scope, %Measurement{} = measurement) do
    Families.authorize!(scope, %Child{id: measurement.child_id}, :caregiver)

    measurement
    |> Repo.delete()
    |> broadcast(measurement.child_id, :deleted)
  end

  ## Helpers ------------------------------------------------------------

  defp put_measured_at(attrs, child, opts) do
    cond do
      match?(%DateTime{}, attrs["measured_at"]) ->
        Map.update!(attrs, "measured_at", &DateTime.truncate(&1, :second))

      is_binary(attrs["measured_at"]) and attrs["measured_at"] != "" ->
        case Date.from_iso8601(attrs["measured_at"]) do
          {:ok, date} -> Map.put(attrs, "measured_at", local_midnight(child, date))
          _ -> maybe_default_measured_at(attrs, child, opts)
        end

      date = parse_date(attrs["measured_on"]) ->
        Map.put(attrs, "measured_at", local_midnight(child, date))

      true ->
        maybe_default_measured_at(attrs, child, opts)
    end
  end

  defp maybe_default_measured_at(attrs, child, opts) do
    if Keyword.get(opts, :default, true) do
      Map.put(attrs, "measured_at", local_midnight(child, Child.local_today(child)))
    else
      attrs
    end
  end

  defp parse_date(%Date{} = date), do: date

  defp parse_date(iso) when is_binary(iso) do
    case Date.from_iso8601(String.trim(iso)) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp local_midnight(%Child{} = child, %Date{} = date) do
    {start, _end} = Child.day_bounds(child, date)
    DateTime.truncate(start, :second)
  end

  defp broadcast({:ok, measurement}, child_id, action) do
    measurement = Repo.preload(measurement, :logged_by, force: true)
    Families.broadcast(child_id, {:growth, action, %{measurement | origin: self()}})
    {:ok, measurement}
  end

  defp broadcast(other, _child_id, _action), do: other

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify(_), do: %{}
end
