defmodule Trygg.Log.VitaminDReminders do
  @moduledoc """
  Evening nudge for children whose caregivers track the daily vitamin D drop
  (`children.vitamin_d_reminder`).

  A drop is logged by ticking it on a bottle feed (`data["vitamin_d"]`). Once a
  child's local clock passes `deadline/0` without one logged for the local
  day, every owner and caregiver gets a Web Push. At most one reminder goes out
  per child per local day: the day is claimed with a conditional update on
  `children.vitamin_d_reminded_on` before anything is sent, so overlapping
  scans can't double up.

  `Trygg.Log.VitaminDReminderWorker` runs this on an Oban cron schedule;
  `run/1` is also safe to call directly (IEx, tests).
  """
  import Ecto.Query

  require Logger

  alias Trygg.Families.Child
  alias Trygg.Log
  alias Trygg.Push.Notifier, as: PushNotifier
  alias Trygg.Repo

  @deadline ~T[18:00:00]

  @doc "The child-local time of day after which a missing drop triggers the reminder."
  @spec deadline() :: Time.t()
  def deadline, do: @deadline

  @doc """
  Runs one scan and returns the number of children reminded.

  `now_fun` resolves a child to its local `DateTime`; overridable for tests.
  """
  @spec run((Child.t() -> DateTime.t())) :: non_neg_integer()
  def run(now_fun \\ &Child.local_now/1) do
    from(c in Child, where: c.vitamin_d_reminder, preload: [memberships: :user])
    |> Repo.all()
    |> Enum.count(&remind(&1, now_fun.(&1)))
  end

  defp remind(child, local_now) do
    today = DateTime.to_date(local_now)

    with false <- Child.expecting?(child),
         false <- child.vitamin_d_reminded_on == today,
         true <- Time.compare(DateTime.to_time(local_now), @deadline) != :lt,
         false <- Log.vitamin_d_given?(child, today),
         true <- claim_day(child, today) do
      child.memberships
      |> Enum.filter(&(&1.role in [:owner, :caregiver] and &1.user))
      |> Enum.each(&PushNotifier.deliver_vitamin_d_reminder(child, &1.user))

      Logger.info("vitamin D reminder sent for child #{child.id}")
      true
    else
      _ -> false
    end
  end

  # Atomically stamp today on the child; only the scan that wins the update
  # sends. Re-checks the toggle so a caregiver switching it off mid-scan wins.
  defp claim_day(child, today) do
    {count, _} =
      Repo.update_all(
        from(c in Child,
          where:
            c.id == ^child.id and c.vitamin_d_reminder and
              (is_nil(c.vitamin_d_reminded_on) or c.vitamin_d_reminded_on < ^today)
        ),
        set: [vitamin_d_reminded_on: today]
      )

    count == 1
  end
end
