defmodule Trygg.Sleep.Nudges do
  @moduledoc """
  Push nudges for sleep, for children whose caregivers turned on
  `children.sleep_nudges`:

    * **Nap window** — they've been awake long enough that the usual window is
      open ("approaching"); once per wake-up.
    * **Feed due** — a newborn asleep by day more than 3 hours after the last
      feed; once per last feed.
    * **Bedtime routine** — from about 8 weeks, 30 minutes before the estimated
      bedtime, when they're awake and bedtime hasn't started; once per evening.

  Nap and feed nudges are daytime only, so a night waking never looks like a
  missed nap. `candidates/1` is pure; `run/1` scans the opted-in children,
  claims each nudge in `sleep_nudge_claims` before sending (so overlapping
  scans can't double up) and fans out via `Trygg.Push.Notifier`.

  `Trygg.Sleep.NudgeWorker` runs `run/1` on an Oban cron schedule.
  """
  import Ecto.Query

  require Logger

  alias Trygg.Accounts.Scope
  alias Trygg.Families.Child
  alias Trygg.Log
  alias Trygg.Push.Notifier
  alias Trygg.Reports
  alias Trygg.Repo

  # Bedtime routine nudges start at this corrected age.
  @routine_from_days 8 * 7
  # How far ahead of the estimated bedtime to nudge: a 25–30 minute routine.
  @routine_lead_seconds 30 * 60
  # Claims are only needed to dedupe within a day or so.
  @claim_ttl_days 7

  @doc "Corrected age, in days, from which the bedtime routine nudge is sent."
  def routine_from_days, do: @routine_from_days

  @doc """
  The nudges due right now from a `Trygg.Reports.sleep_plan/4` map (plus
  `:child` and `:now`): a list of `%{kind, key, title, body}`.
  """
  def candidates(%{child: child, now: now} = ctx) do
    if Child.daytime?(child, now) or bedtime_soon?(ctx) do
      [nap_window(ctx), feed_due(ctx), bedtime_routine(ctx)] |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp bedtime_soon?(%{prediction: %{bedtime: %{at: at}}, now: now}),
    do: DateTime.diff(at, now, :second) in 0..@routine_lead_seconds

  defp bedtime_soon?(_ctx), do: false

  defp nap_window(%{child: child, now: now} = ctx) do
    with true <- Child.daytime?(child, now),
         %{} = insight <- insight(ctx, "nap-window"),
         %DateTime{} = anchor <- ctx.prediction.anchor_ts do
      %{
        kind: :nap_window,
        key: "nap-window:#{DateTime.to_unix(anchor)}",
        title: "#{child.name}'s nap window is open",
        body: insight.detail
      }
    else
      _ -> nil
    end
  end

  defp feed_due(%{child: child, now: now, last_feed_at: %DateTime{} = fed} = ctx) do
    with true <- Child.daytime?(child, now),
         %{} = insight <- insight(ctx, "feed-due") do
      %{
        kind: :feed_due,
        key: "feed-due:#{DateTime.to_unix(fed)}",
        title: "#{child.name} may be due a feed",
        body: insight.detail
      }
    else
      _ -> nil
    end
  end

  defp feed_due(_ctx), do: nil

  defp bedtime_routine(
         %{phase: %{age_days: age}, prediction: %{state: :awake, bedtime: %{at: at} = bed}} = ctx
       )
       when age >= @routine_from_days do
    until = DateTime.diff(at, ctx.now, :second)

    if until in 0..@routine_lead_seconds and not bedtime_started?(ctx.today) do
      local = DateTime.shift_zone!(at, ctx.child.timezone)

      %{
        kind: :bedtime_routine,
        key: "bedtime:#{DateTime.to_date(local)}",
        title: "Bedtime routine for #{ctx.child.name}",
        body:
          "Bedtime looks like #{bed.label}. A 25–30 minute wind-down (diaper, pajamas, feed, " <>
            "then to the nursery) starts about now."
      }
    end
  end

  defp bedtime_routine(_ctx), do: nil

  defp bedtime_started?(%{bedtime: %DateTime{}}), do: true
  defp bedtime_started?(_today), do: false

  defp insight(%{insights: insights}, id), do: Enum.find(insights, &(&1.id == id))

  ## Scanning --------------------------------------------------------------

  @doc """
  Scans every opted-in child and returns how many nudges were sent. `now` is
  injectable for tests.
  """
  def run(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)
    prune_claims(now)

    from(c in Child, where: c.sleep_nudges, preload: [memberships: :user])
    |> Repo.all()
    |> Enum.map(&scan(&1, now))
    |> Enum.sum()
  end

  defp scan(child, now) do
    recipients =
      for m <- child.memberships, m.role in [:owner, :caregiver], m.user, do: m.user

    with false <- Child.expecting?(child),
         true <- Child.tracks?(child, :sleep),
         [first | _] <- recipients do
      scope = Scope.for_user(first)
      summary = Log.summary(scope, child)

      plan =
        Reports.sleep_plan(scope, child, now, last_feed_at: Log.last_feed_at(summary))

      ctx =
        plan
        |> Map.take([:prediction, :today, :insights, :phase])
        |> Map.merge(%{child: child, now: now, last_feed_at: Log.last_feed_at(summary)})

      ctx
      |> candidates()
      |> Enum.count(&send_nudge(child, recipients, &1, now))
    else
      _ -> 0
    end
  end

  defp send_nudge(child, recipients, nudge, now) do
    if claim(child, nudge.key, now) do
      Enum.each(recipients, &Notifier.deliver_sleep_nudge(child, &1, nudge))
      Logger.info("sleep nudge #{nudge.kind} sent for child #{child.id}")
      true
    else
      false
    end
  end

  # Only the scan that inserts the claim sends.
  defp claim(child, key, now) do
    {count, _} =
      Repo.insert_all(
        "sleep_nudge_claims",
        [%{child_id: child.id, key: key, inserted_at: now}],
        on_conflict: :nothing,
        conflict_target: [:child_id, :key]
      )

    count == 1
  end

  defp prune_claims(now) do
    cutoff = DateTime.add(now, -@claim_ttl_days * 86_400, :second)
    Repo.delete_all(from(c in "sleep_nudge_claims", where: c.inserted_at < ^cutoff))
  end
end
