defmodule Trygg.Growth.ReminderScheduler do
  @moduledoc """
  Periodically emails a child's caregivers when a routine weight check is
  overdue (see `Trygg.Growth.CheckReminder`).

  A single in-process timer, enough for one Fly machine. The
  `growth_reminder_notifications` table — not process state — remembers who
  has already been nudged, so a redeploy or a fast tick can't spam anyone:
  a child's next reminder waits a full check interval after the last one.

  Disabled in `:test`; call `run/0` directly there.
  """
  use GenServer
  import Ecto.Query

  require Logger

  alias Trygg.Families.Child
  alias Trygg.Families.FamilyNotifier
  alias Trygg.Growth.CheckReminder
  alias Trygg.Growth.Measurement
  alias Trygg.Growth.ReminderNotification
  alias Trygg.Repo

  @tick_interval :timer.hours(6)
  @boot_delay :timer.seconds(60)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    if enabled?(), do: Process.send_after(self(), :tick, @boot_delay)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    run()
    Process.send_after(self(), :tick, @tick_interval)
    {:noreply, state}
  end

  @doc """
  Scans every child once and sends any weight-check reminders that are due.
  Safe to call directly (tests, IEx). Returns the number of children whose
  caregivers were emailed.

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
      status = CheckReminder.evaluate(child, Map.get(latest, child.id), today)

      if status && status.due? && due_for_email?(child, status, today) do
        notify(child, status, today)
        sent + 1
      else
        sent
      end
    end)
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

  defp due_for_email?(child, status, today) do
    case Repo.get_by(ReminderNotification, child_id: child.id) do
      nil -> true
      %ReminderNotification{last_notified_on: on} -> Date.diff(today, on) >= status.interval_days
    end
  end

  defp notify(child, status, today) do
    emails =
      child.memberships
      |> Enum.filter(&(&1.role in [:owner, :caregiver] and &1.user))
      |> Enum.map(& &1.user.email)
      |> Enum.uniq()

    url = TryggWeb.Endpoint.url() <> "/c/#{child.id}/vitals"

    Enum.each(emails, &FamilyNotifier.deliver_weight_check_reminder(&1, child, status, url))
    record(child, status, today)

    Logger.info(
      "weight-check reminder sent for child #{child.id} to #{length(emails)} caregiver(s)"
    )
  end

  defp record(child, status, today) do
    row =
      Repo.get_by(ReminderNotification, child_id: child.id) ||
        %ReminderNotification{child_id: child.id}

    row
    |> ReminderNotification.changeset(%{
      last_notified_on: today,
      last_measured_on: status.last_measured_on
    })
    |> Repo.insert_or_update!()
  end

  defp enabled? do
    Application.get_env(:trygg, __MODULE__, []) |> Keyword.get(:enabled, true)
  end
end
