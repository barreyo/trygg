defmodule Trygg.SleepSimulator do
  @moduledoc """
  Generates realistic multi-week infant sleep logs for end-to-end prediction
  tests.

  Given a child with a `birth_date`, it builds an age-appropriate schedule —
  morning wake, a run of naps with age-typical wake windows and durations, and
  a bedtime — then adds day-to-day and within-day jitter, occasional catnaps,
  the odd "rough day", and brief night wakings.

  `plan/4` returns the schedule and a chronological list of tagged sleep
  `blocks` without touching the database, so a test can replay a day at a time
  (insert a block, then predict) the way the real app sees a log fill in.
  `generate/4` plans and bulk-inserts everything at once.

  It is deterministic for a given `:seed`. Schedules keep the last nap well
  before `night_start - 3h` and bedtime at/after `night_start`, so
  `Trygg.Reports.Day`'s overnight-cluster logic segments them like a real log.
  Use a child whose `day_start` is early (e.g. 06:00).
  """

  alias Trygg.Families.Child
  alias Trygg.Log.Entry
  alias Trygg.Repo

  # {min_age_days, %{wake: morning-wake minutes-from-midnight,
  #                  ww: [wake→nap1, nap1→nap2, …, last-nap→bed] minutes,
  #                  nap: [nap durations] minutes}}
  # `ww` always has one more entry than `nap`.
  @models [
    {0, %{wake: 400, ww: [70, 80, 85, 95, 110], nap: [55, 70, 55, 35]}},
    {110, %{wake: 410, ww: [95, 120, 140, 175], nap: [75, 85, 45]}},
    {180, %{wake: 415, ww: [160, 195, 240], nap: [85, 80]}},
    {300, %{wake: 420, ww: [180, 220, 255], nap: [80, 75]}},
    {440, %{wake: 425, ww: [305, 320], nap: [105]}},
    {560, %{wake: 430, ww: [335, 335], nap: [110]}}
  ]

  @doc "The built-in schedule model for `age_days`."
  def model(age_days) do
    @models
    |> Enum.reverse()
    |> Enum.find(fn {min, _} -> age_days >= min end)
    |> elem(1)
  end

  @doc "How many naps the built-in model uses at `age_days`."
  def nap_count(age_days), do: length(model(age_days).nap)

  @doc """
  Plans `days` local days of sleep for `child`, the most recent ending on
  `end_date`. Returns

      %{timeline: [%{date, age_days, wake_at, naps: [{DateTime, DateTime}],
                     bedtime_at}],
        blocks:   [%{started_at, ended_at, wake?}]}

  both oldest first. `blocks` is chronological and covers naps plus overnight
  sleep (sometimes split by a night waking); `wake?` marks the block ends that
  are a real morning wake or nap end — where a prediction is due.

  Options: `:seed` (default 42), `:jitter` (`:low | :normal | :high`),
  `:model` (`fun(age_days) -> model_map`), `:night_waking_chance` (default 0.4).
  """
  def plan(%Child{birth_date: %Date{}} = child, %Date{} = end_date, days, opts \\ [])
      when is_integer(days) and days > 0 do
    seed = Keyword.get(opts, :seed, 42)
    :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})

    sd = jitter_sd(Keyword.get(opts, :jitter, :normal))
    model_fun = Keyword.get(opts, :model, &model/1)
    nw_chance = Keyword.get(opts, :night_waking_chance, 0.4)

    dates = for i <- (days - 1)..0//-1, do: Date.add(end_date, -i)
    sims = Enum.map(dates, &simulate_day(child, &1, model_fun.(age_days(child, &1)), sd))

    %{
      timeline: Enum.map(sims, &to_timeline(child, &1)),
      blocks: build_blocks(child, sims, nw_chance)
    }
  end

  @doc "Plans and inserts `days` of sleep. Returns the timeline."
  def generate(%Child{} = child, %Date{} = end_date, days, opts \\ []) do
    %{timeline: timeline, blocks: blocks} = plan(child, end_date, days, opts)
    insert_blocks(child, blocks, opts[:logged_by_id])
    timeline
  end

  @doc "Inserts sleep `blocks` (from `plan/4`) as `:sleep` entries for `child`."
  def insert_blocks(%Child{} = child, blocks, logged_by_id \\ nil) do
    stamp = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(blocks, fn b ->
        %{
          child_id: child.id,
          logged_by_id: logged_by_id,
          type: :sleep,
          started_at: b.started_at,
          ended_at: b.ended_at,
          data: %{"location" => "bassinet"},
          note: nil,
          inserted_at: stamp,
          updated_at: stamp
        }
      end)

    Repo.insert_all(Entry, rows)
    :ok
  end

  ## Schedule ----------------------------------------------------------------

  defp simulate_day(child, date, model, sd) do
    rough = :rand.uniform() < 0.08
    spread = if rough, do: sd * 1.7, else: sd

    wake = model.wake + jitter(sd)

    {naps_rev, cursor} =
      model.nap
      |> Enum.with_index()
      |> Enum.reduce({[], wake}, fn {dur, i}, {acc, t} ->
        start = t + Enum.at(model.ww, i) + jitter(spread)

        length =
          if :rand.uniform() < 0.1,
            do: dur * (0.4 + :rand.uniform() * 0.15),
            else: dur + jitter(sd * 0.6)

        finish = start + max(length, 12)
        {[{start, finish} | acc], finish}
      end)

    bedtime = cursor + List.last(model.ww) + jitter(spread)

    %{
      date: date,
      age_days: age_days(child, date),
      wake_min: round(wake),
      naps_min: naps_rev |> Enum.reverse() |> Enum.map(fn {s, f} -> {round(s), round(f)} end),
      bed_min: round(bedtime)
    }
  end

  defp to_timeline(child, sim) do
    %{
      date: sim.date,
      age_days: sim.age_days,
      wake_at: at(child, sim.date, sim.wake_min),
      naps:
        Enum.map(sim.naps_min, fn {s, f} -> {at(child, sim.date, s), at(child, sim.date, f)} end),
      bedtime_at: at(child, sim.date, sim.bed_min)
    }
  end

  ## Blocks --------------------------------------------------------------

  defp build_blocks(child, sims, nw_chance) do
    first = hd(sims)
    morning0 = at(child, first.date, first.wake_min)

    lead_in = %{
      started_at: DateTime.add(morning0, -(690 * 60), :second),
      ended_at: morning0,
      wake?: true
    }

    naps =
      for sim <- sims, {s, f} <- sim.naps_min do
        %{started_at: at(child, sim.date, s), ended_at: at(child, sim.date, f), wake?: true}
      end

    nights =
      sims
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [a, b] -> night_blocks(child, a, b, nw_chance) end)

    ([lead_in] ++ naps ++ nights)
    |> Enum.sort_by(& &1.started_at, DateTime)
  end

  defp night_blocks(child, a, b, nw_chance) do
    bed = at(child, a.date, a.bed_min)
    morning = at(child, b.date, b.wake_min)

    if :rand.uniform() < nw_chance do
      woke = DateTime.add(bed, 7200 + :rand.uniform(14_400), :second)
      back = DateTime.add(woke, 300 + :rand.uniform(420), :second)

      if DateTime.compare(back, morning) == :lt do
        [
          %{started_at: bed, ended_at: woke, wake?: false},
          %{started_at: back, ended_at: morning, wake?: true}
        ]
      else
        [%{started_at: bed, ended_at: morning, wake?: true}]
      end
    else
      [%{started_at: bed, ended_at: morning, wake?: true}]
    end
  end

  ## Helpers ------------------------------------------------------------

  defp age_days(%Child{birth_date: dob}, %Date{} = date), do: Date.diff(date, dob)

  defp at(child, date, minutes) do
    minutes = max(minutes, 0)
    Child.at_local(child, date, Time.new!(div(minutes, 60), rem(minutes, 60), 0))
  end

  defp jitter_sd(:low), do: 8
  defp jitter_sd(:normal), do: 13
  defp jitter_sd(:high), do: 22

  # Gaussian noise in minutes, clamped to ±3 sd.
  defp jitter(sd), do: (:rand.normal() * sd) |> max(-3 * sd) |> min(3 * sd)
end
