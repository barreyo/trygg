defmodule Trygg.Growth.WeightReminders do
  @moduledoc """
  Scans every child and emails each caregiver whose routine weight check is
  overdue.

  Each caregiver is evaluated on their own cadence
  (`Trygg.Accounts.User.weight_reminder_setting/1`): the CDC well-child
  schedule by default, a fixed number of days, or off. The
  `growth_reminder_notifications` table holds one row per `{child, caregiver}`
  so a re-run only re-sends once that caregiver's interval has elapsed.

  `Trygg.Growth.WeightReminderWorker` runs this on an Oban cron schedule;
  `run/0` is also safe to call directly (IEx, tests).
  """
  import Ecto.Query

  require Logger

  alias Trygg.Accounts.User
  alias Trygg.Families.Child
  alias Trygg.Families.FamilyNotifier
  alias Trygg.Growth.CheckReminder
  alias Trygg.Growth.Measurement
  alias Trygg.Growth.ReminderNotification
  alias Trygg.Repo

  @doc """
  Runs one full scan. Returns the number of reminder emails sent.

  `today_fun` resolves a child to its local calendar date; overridable for
  tests.
  """
  @spec run((Child.t() -> Date.t())) :: non_neg_integer()
  def run(today_fun \\ &Child.local_today/1) do
    latest = latest_weights()

    from(c in Child, preload: [memberships: :user])
    |> Repo.all()
    |> Enum.reduce(0, fn child, sent ->
      today = today_fun.(child)
      weight = Map.get(latest, child.id)

      due =
        child.memberships
        |> Enum.filter(&(&1.role in [:owner, :caregiver] and &1.user))
        |> Enum.flat_map(&due_for(&1.user, child, weight, today))

      Enum.each(due, fn {user, status} ->
        FamilyNotifier.deliver_weight_check_reminder(user.email, child, status, url(child))
        record(child.id, user.id, status, today)
      end)

      if due != [] do
        Logger.info(
          "weight-check reminder sent for child #{child.id} to #{length(due)} caregiver(s)"
        )
      end

      sent + length(due)
    end)
  end

  # `[{user, status}]` when this caregiver should be emailed now, else `[]`.
  defp due_for(%User{} = user, child, weight, today) do
    with interval when interval != :off <- caregiver_interval(user),
         %{due?: true} = status <- CheckReminder.evaluate(child, weight, today, interval),
         true <- needs_email?(child.id, user.id, status, today) do
      [{user, status}]
    else
      _ -> []
    end
  end

  # `nil` (CDC schedule) or a positive day count, or `:off`.
  defp caregiver_interval(%User{} = user) do
    case User.weight_reminder_setting(user) do
      :recommended -> nil
      :off -> :off
      {:every, days} -> days
    end
  end

  # The most recent weight reading per child, in one query.
  defp latest_weights do
    from(m in Measurement,
      where: not is_nil(m.weight_g),
      distinct: m.child_id,
      order_by: [asc: m.child_id, desc: m.measured_at, desc: m.id]
    )
    |> Repo.all()
    |> Map.new(&{&1.child_id, &1})
  end

  defp needs_email?(child_id, user_id, status, today) do
    case Repo.get_by(ReminderNotification, child_id: child_id, user_id: user_id) do
      nil -> true
      %ReminderNotification{last_notified_on: on} -> Date.diff(today, on) >= status.interval_days
    end
  end

  defp record(child_id, user_id, status, today) do
    row =
      Repo.get_by(ReminderNotification, child_id: child_id, user_id: user_id) ||
        %ReminderNotification{child_id: child_id, user_id: user_id}

    row
    |> ReminderNotification.changeset(%{
      last_notified_on: today,
      last_measured_on: status.last_measured_on
    })
    |> Repo.insert_or_update!()
  end

  defp url(child), do: TryggWeb.Endpoint.url() <> "/c/#{child.id}/vitals"
end
