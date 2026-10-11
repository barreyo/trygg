# Local-dev sleep seeds, loaded by `priv/repo/dev_seeds.exs` (`mix seed.dev`).
#
# Astrid (the newborn from the main seed) gets sleepy cues on her sleeps,
# C.R.I.E.S. night wakings (one still in progress, so the Sleep tab banner and
# night mode have something to resume) and part of the safe-sleep checklist.
#
# Then three more babies join her family so every stage and every sleep feature
# has something to show, each with a month or so of days and nights built from
# the same pattern generator:
#
#   Freja   4½ months  Foundations. A gradual plan (SWAP: "pat the back") on night 4,
#                      how she falls asleep climbing the 1–9 scale, sleepy cues,
#                      night feeds with all three gates open, S.I.T. B.A.C.K. wakings,
#                      push nudges on, and the playbooks page full of findings
#                      (early mornings, short naps, a regression window).
#   Linnea 5 months    The Sleep Learning Independence Plan (graduated) on night 5 with
#                      a bounce-back on night 4 (an extinction burst), a stopped
#                      SWAP before it, bedtimes that wandered before the plan, long
#                      night wakes, and a weigh-in that's too old to open night weaning.
#   Sigrid 7 months    "The ABCs of Sleep" on night 9: pop-ins and notes, a night-weaning
#                      table (two bottle feeds down to none), nights stretching to 11
#                      hours, a thin third nap that leaves too little time awake before
#                      bed, the pacifier flagged as a problem.
#
# A second caregiver (partner@johanbackman.com) shares the family so night-mode
# wakings show who started them. Re-running wipes and regenerates all of it.

defmodule Trygg.DevSeeds.Sleep do
  import Ecto.Query

  alias Trygg.{Accounts, Families, Repo}
  alias Trygg.Accounts.Scope
  alias Trygg.Families.{Child, Membership}
  alias Trygg.Growth.{Measurement, Percentiles}
  alias Trygg.Log.Entry
  alias Trygg.Sleep.{Abcs, Checkins, NightWake, Phase, Plan, Plans, SafeSleep, Slip, Swap}

  @tz "Europe/Stockholm"
  @partner_email "partner@johanbackman.com"

  # A baby's pattern is a map of functions of `j`, the day's offset from the
  # evening a night started now would belong to (0 is that evening, -1 the one
  # before): `:wake`, `:bed` (when they're put down), `:settle` (minutes to fall
  # asleep), `:naps` (a function of `j` and the morning's wake time, `[{wake_window, length}]`), `:wakings` (`[%{at, mins, feed}]`,
  # `at` minutes after falling asleep) and `:assist` (`{level, settle}`), plus
  # `:cues`, `:nap_place`, `:feed_ml` and the child. Times are minutes after
  # local midnight.

  def run(%{user: user, scope: scope, astrid: astrid, now: now}) do
    :rand.seed(:exsss, {20_261_011, 3, 11})

    partner = upsert_partner(now)
    family_id = astrid.family_id
    add_partner(family_id, partner)

    astrid_summary = seed_astrid(scope, user, partner, astrid, now)

    freja = upsert_child(scope, family_id, "Freja", 137, :female, sleep_nudges: true)
    linnea = upsert_child(scope, family_id, "Linnea", 150, :female)
    sigrid = upsert_child(scope, family_id, "Sigrid", 215, :female)

    [freja, linnea, sigrid]
    |> Enum.each(fn child -> wipe(child) end)

    summaries = [
      seed_freja(scope, user, partner, freja, now),
      seed_linnea(scope, user, partner, linnea, now),
      seed_sigrid(scope, user, partner, sigrid, now)
    ]

    [astrid_summary | summaries]
  end

  ## People ---------------------------------------------------------------------

  defp upsert_partner(now) do
    case Accounts.get_user_by_email(@partner_email) do
      nil ->
        {:ok, user} =
          Accounts.register_user(%{
            email: @partner_email,
            first_name: "Partner",
            last_name: "Backman"
          })

        user |> Ecto.Changeset.change(confirmed_at: now, unit_system: :metric) |> Repo.update!()

      user ->
        user
    end
  end

  defp add_partner(family_id, partner) do
    unless Repo.get_by(Membership, family_id: family_id, user_id: partner.id) do
      %Membership{family_id: family_id, user_id: partner.id}
      |> Membership.changeset(%{role: :caregiver})
      |> Repo.insert!()
    end
  end

  defp upsert_child(scope, family_id, name, age_days, sex, extra \\ []) do
    birth = Date.add(Date.utc_today(), -age_days)

    attrs =
      Map.merge(
        %{name: name, birth_date: birth, sex: sex, timezone: @tz, sleep_nudges: false},
        Map.new(extra)
      )

    case Enum.find(Families.list_children(scope), &(&1.name == name)) do
      nil ->
        {:ok, child} = Families.create_child(scope, attrs, family_id: family_id)
        child

      existing ->
        {:ok, child} = Families.update_child(scope, existing, attrs)
        child
    end
  end

  # Everything a re-run regenerates for a child.
  defp wipe(child) do
    Repo.delete_all(from(w in NightWake, where: w.child_id == ^child.id))
    Repo.delete_all(from(p in Plan, where: p.child_id == ^child.id))
    Repo.delete_all(from(e in Entry, where: e.child_id == ^child.id))
    Repo.delete_all(from(m in Measurement, where: m.child_id == ^child.id))
  end

  ## Astrid: the newborn ------------------------------------------------------------

  defp seed_astrid(scope, user, partner, astrid, now) do
    Repo.delete_all(from(w in NightWake, where: w.child_id == ^astrid.id))

    # Sleepy cues on most of this week's sleeps.
    week_ago = DateTime.add(now, -7 * 86_400, :second)

    sleeps =
      Repo.all(
        from(e in Entry,
          where: e.child_id == ^astrid.id and e.type == :sleep and e.started_at >= ^week_ago,
          order_by: e.started_at
        )
      )

    cued =
      for sleep <- sleeps, :rand.uniform() < 0.6 do
        cue = pick([{"tired", 45}, {"ready", 35}, {"overtired", 20}])
        data = Map.put(sleep.data || %{}, "cue", cue)
        Repo.update_all(from(e in Entry, where: e.id == ^sleep.id), set: [data: data])
      end

    # C.R.I.E.S. wakings over the last week; one is still going.
    steps = [{4, :settled}, {2, :settled}, {3, :settled}, {1, :settled}, {4, :fed}, {2, :settled}]

    for {{step, outcome}, i} <- Enum.with_index(steps) do
      started = DateTime.add(now, -(i * 29 + 5) * 3600, :second) |> DateTime.truncate(:second)

      insert_wake(astrid, %{
        method: :cries,
        kind: :waking,
        started_at: started,
        step_started_at: DateTime.add(started, step * 120, :second),
        ended_at: DateTime.add(started, (step + 1) * 140, :second),
        step: step,
        settled_step: step,
        outcome: outcome,
        started_by_id: if(rem(i, 2) == 0, do: user.id, else: partner.id)
      })
    end

    started = DateTime.add(now, -150, :second) |> DateTime.truncate(:second)

    insert_wake(astrid, %{
      method: :cries,
      kind: :waking,
      started_at: started,
      step_started_at: DateTime.add(started, 60, :second),
      step: 1,
      started_by_id: partner.id
    })

    # Safe sleep: most of it ticked.
    ticks =
      SafeSleep.ids()
      |> Enum.take(9)
      |> Map.new(&{&1, Date.to_iso8601(Date.add(Date.utc_today(), -3))})

    {:ok, _} = Families.update_sleep_toolkit(scope, astrid, %{sleep_checks: ticks})

    %{
      name: astrid.name,
      note: "#{length(cued)} sleeps with cues, 7 C.R.I.E.S. wakings (1 running)"
    }
  end

  ## Freja: Foundations, a gradual plan on night 4 ------------------------------------

  defp seed_freja(scope, user, partner, child, now) do
    today = local_today(now)

    cfg = %{
      child: child,
      days: 40,
      # Mornings slip to 4:50–5:20 on most of the last week.
      wake: fn j ->
        if j >= -6 and rem(j, 7) not in [-2, -5],
          do: 5 * 60 + jit(0, 20),
          else: 6 * 60 + 45 + jit(0, 14)
      end,
      # Bedtime comes earlier as sleep debt builds: 18:45 this week, about 19:10 before.
      bed: fn j -> if j >= -7, do: 18 * 60 + 45 + jit(0, 6), else: 19 * 60 + 10 + jit(0, 12) end,
      settle: fn j -> max(40 + div(j, 2), 8) + jit(0, 5) end,
      naps: fn j, wake ->
        # This week, four naps, the first two short. After an early start the first window
        # is long; when they got up later the windows are shorter, so the day ends the same.
        # Before that, three naps and a short fourth.
        cond do
          j >= -7 and wake < 6 * 60 ->
            [
              {140, 34 + jit(0, 5)},
              {110, 36 + jit(0, 5)},
              {115, 38 + jit(0, 6)},
              {135, 36 + jit(0, 6)}
            ]

          j >= -7 ->
            [
              {100, 34 + jit(0, 5)},
              {105, 36 + jit(0, 5)},
              {110, 38 + jit(0, 6)},
              {120, 36 + jit(0, 6)}
            ]

          true ->
            [
              {90, 44 + jit(0, 5)},
              {100, 42 + jit(0, 5)},
              {110, 30 + jit(0, 8)},
              {140, 25 + jit(0, 6)}
            ]
        end
      end,
      wakings: fn _j ->
        [
          %{at: 175 + jit(0, 20), mins: 20, feed: 105},
          %{at: 400 + jit(0, 25), mins: 18, feed: 100}
        ]
      end,
      assist: fn j -> level_for(j, 40, 2, 4) end,
      cues: [{"tired", 40}, {"ready", 45}, {"overtired", 15}],
      nap_place: fn _j, _n -> pick([{"crib", 45}, {"contact", 30}, {"stroller", 25}]) end,
      feed_ml: 150
    }

    {:ok, child} =
      Families.update_sleep_toolkit(scope, child, %{
        night_weaning_cleared_on: Date.add(today, -3),
        sleep_training_cleared_on: Date.add(today, -3),
        sleep_checks:
          checks(
            today,
            [
              "environment",
              "routine",
              "crib",
              "rough-night-plan",
              "t-feeds",
              "t-environment",
              "t-windows",
              "pt-swaddle-escapes"
            ] ++
              Enum.take(SafeSleep.ids(), 11) ++
              Swap.preflight_ids() ++ Enum.take(Slip.preflight_ids(), 6)
          )
      })

    evening = evening_date(now)
    started_on = Date.add(evening, -3)

    plan_nights =
      for n <- 1..3 do
        {n, %{settle: [38, 31, 24] |> Enum.at(n - 1), went_in: [3, 2, 1] |> Enum.at(n - 1)}}
      end

    rows = generate(cfg, user, partner, now, plan_nights: plan_nights, plan_started: started_on)
    insert_rows(rows)
    weigh_ins(child, user, [{-120, 0.3}, {-90, 0.35}, {-62, 0.4}, {-31, 0.4}, {-9, 0.45}], now)

    {:ok, plan} =
      Plans.start(scope, child, Phase.for_child(child), %{
        definition: :swap,
        options: %{"variant" => "pat", "start_minutes" => 35},
        started_on: started_on
      })

    for {n, spec} <- plan_nights do
      swap_night(child, plan, n, spec, user, partner)
    end

    {:ok, _} =
      Plans.put_note(scope, plan, 1, "Hard, but she fell asleep in the crib with the pat.")

    {:ok, _} = Plans.put_note(scope, plan, 2, "Better. Cut the pat short at 30.")

    # S.I.T. B.A.C.K. wakings from before the plan.
    for {i, step, outcome} <- [
          {2, 1, :settled},
          {3, 3, :settled},
          {5, 6, :fed},
          {6, 2, :settled},
          {9, 4, :settled}
        ] do
      started = DateTime.add(now, -(i * 26 + 3) * 3600, :second) |> DateTime.truncate(:second)

      insert_wake(child, %{
        method: :sit_back,
        kind: :waking,
        started_at: started,
        step_started_at: DateTime.add(started, 300, :second),
        ended_at: DateTime.add(started, 300 + step * 130, :second),
        step: step,
        settled_step: step,
        outcome: outcome,
        started_by_id: if(rem(i, 2) == 0, do: user.id, else: partner.id)
      })
    end

    %{name: child.name, note: "a SWAP (pat the back) on night 4, #{length(rows)} entries"}
  end

  ## Linnea: SLIP, graduated, night 5 -------------------------------------------------------

  defp seed_linnea(scope, user, partner, child, now) do
    today = local_today(now)
    evening = evening_date(now)
    started_on = Date.add(evening, -4)

    # Before the plan bedtimes wandered from 18:45 to 20:30; on the plan it's steady.
    wander = %{
      -40 => 20 * 60 + 10,
      -37 => 18 * 60 + 50,
      -34 => 20 * 60 + 30,
      -31 => 19 * 60,
      -28 => 20 * 60,
      -26 => 18 * 60 + 45
    }

    cfg = %{
      child: child,
      days: 40,
      wake: fn _j -> 6 * 60 + 30 + jit(0, 10) end,
      bed: fn j ->
        cond do
          j >= -4 -> 19 * 60 + 15
          true -> Map.get(wander, j, 19 * 60 + 20 + jit(-30, 60))
        end
      end,
      settle: fn j -> if j >= -4, do: 12, else: 25 + jit(0, 15) end,
      naps: fn _j, _wake ->
        [{135, 60 + jit(0, 8)}, {135, 55 + jit(0, 8)}, {140, 35 + jit(0, 8)}]
      end,
      wakings: fn j ->
        # A long gap in the small hours on most of the nights before the plan.
        if j in [-10, -9, -8, -7, -6, -5],
          do: [%{at: 360 + jit(0, 20), mins: 75 + jit(0, 20), feed: nil}],
          else: [%{at: 200 + jit(0, 30), mins: 15, feed: 110}]
      end,
      assist: fn j -> if j >= -4, do: {9, 40}, else: level_for(j, 40, 3, 5) end,
      cues: [{"tired", 50}, {"ready", 40}, {"overtired", 10}],
      nap_place: fn _j, _n -> pick([{"crib", 70}, {"stroller", 30}]) end,
      feed_ml: 170
    }

    {:ok, child} =
      Families.update_sleep_toolkit(scope, child, %{
        sleep_training_cleared_on: Date.add(today, -12),
        sleep_checks:
          checks(
            today,
            Slip.preflight_ids() ++
              Swap.preflight_ids() ++
              ["environment", "routine", "crib"] ++ Enum.take(SafeSleep.ids(), 14)
          )
      })

    # A gradual plan that was stopped a couple of weeks ago is why SLIP is the next step.
    {:ok, earlier} =
      %Plan{child_id: child.id, started_by_id: user.id}
      |> Plan.changeset(%{
        definition: :swap,
        status: :stopped,
        started_on: Date.add(today, -24),
        ended_on: Date.add(today, -17),
        options: %{"variant" => "jiggle", "start_minutes" => 30}
      })
      |> Repo.insert()

    _ = earlier

    plan_nights =
      for n <- 1..4, do: {n, slip_night(n)}

    rows = generate(cfg, user, partner, now, plan_nights: plan_nights, plan_started: started_on)
    insert_rows(rows)

    # The last weigh-in is too old to open night weaning: a gate showing.
    weigh_ins(child, user, [{-140, 0.3}, {-110, 0.3}, {-80, 0.35}, {-45, 0.35}], now)

    {:ok, plan} =
      Plans.start(scope, child, Phase.for_child(child), %{
        definition: :slip,
        options: %{"mode" => "graduated"},
        started_on: started_on
      })

    for {n, spec} <- plan_nights, do: slip_wakes(child, plan, n, spec, user, partner)

    {:ok, _} = Plans.put_note(scope, plan, 1, "Over an hour. We stuck to it.")
    {:ok, _} = Plans.put_note(scope, plan, 3, "Fell asleep in 12 minutes. Same words each visit.")
    {:ok, _} = Plans.put_note(scope, plan, 4, "Worse again. Reading about extinction bursts.")

    %{
      name: child.name,
      note: "a graduated SLIP on night 5 with a bounce-back on night 4, #{length(rows)} entries"
    }
  end

  # Crying at bedtime: 78, 32, 12 minutes then 41 again. Visits grow with the night
  # (night 1: 5, +10, +15 ...; night 2: 10, +15 ...).
  defp slip_night(1),
    do: %{cry: 78, visits: [5, 15, 30, 50, 75], wakings: [{240, 10, [5]}, {400, 25, [10]}]}

  defp slip_night(2), do: %{cry: 32, visits: [10, 25], wakings: [{300, 20, [10]}]}
  defp slip_night(3), do: %{cry: 12, visits: [], wakings: [{360, 8, []}]}
  defp slip_night(4), do: %{cry: 41, visits: [20], wakings: [{330, 14, [5]}]}

  ## Sigrid: The ABCs of Sleep, night 9 --------------------------------------------------------

  defp seed_sigrid(scope, user, partner, child, now) do
    today = local_today(now)
    evening = evening_date(now)
    started_on = Date.add(evening, -8)

    cfg = %{
      child: child,
      days: 40,
      wake: fn j -> if j >= -2, do: 6 * 60 + 25 + jit(0, 8), else: 6 * 60 + 50 + jit(0, 12) end,
      bed: fn _j -> 19 * 60 + 30 end,
      settle: fn j -> if j >= -8, do: 25, else: 30 + jit(0, 10) end,
      # The third nap is thin and late: it ends about 2½ hours before she falls asleep.
      naps: fn _j, _wake ->
        [{140, 75 + jit(0, 8)}, {150, 70 + jit(0, 8)}, {170, 15 + jit(0, 5)}]
      end,
      wakings: fn j ->
        cond do
          # The plan's nights (night 1 is -8): fewer wakings, and feeds weaned off.
          j >= -8 -> sigrid_wakings(j + 9)
          true -> [%{at: 190, mins: 20, feed: 150}, %{at: 440, mins: 20, feed: 150}]
        end
      end,
      assist: fn j -> if j >= -8, do: {9, 20}, else: level_for(j, 40, 4, 6) end,
      cues: [{"tired", 55}, {"ready", 35}, {"overtired", 10}],
      nap_place: fn _j, _n -> pick([{"crib", 92}, {"stroller", 8}]) end,
      feed_ml: 200
    }

    {:ok, child} =
      Families.update_sleep_toolkit(scope, child, %{
        night_weaning_cleared_on: Date.add(today, -10),
        sleep_training_cleared_on: Date.add(today, -10),
        sleep_checks:
          checks(
            today,
            Abcs.preflight_ids() ++
              ["pt-paci-night", "environment", "routine", "crib", "swaddle", "props"] ++
              Enum.take(SafeSleep.ids(), 12)
          )
      })

    plan_nights =
      for n <- 1..8, do: {n, sigrid_night(n)}

    rows = generate(cfg, user, partner, now, plan_nights: plan_nights, plan_started: started_on)
    insert_rows(rows)

    weigh_ins(
      child,
      user,
      [{-190, 0.4}, {-160, 0.4}, {-130, 0.45}, {-95, 0.45}, {-60, 0.5}, {-5, 0.5}],
      now
    )

    {:ok, plan} =
      Plans.start(scope, child, Phase.for_child(child), %{
        definition: :abcs,
        feed_kind: :bottle,
        feed_times: [22 * 60 + 30, 3 * 60 + 30],
        feed_amounts: [150, 150],
        started_on: started_on
      })

    for {n, spec} <- plan_nights, do: abcs_wakes(child, plan, n, spec, user, partner)

    notes = %{
      1 => "Two hours of crying in total. Dad did the 3 am pop-in.",
      3 => "Tough. Whining more than crying by the end.",
      5 => "First night with no feeds. Slept to 5:40.",
      6 => "Slept 10 hours straight.",
      8 => "11 hours! Praise and lights on at 6:30."
    }

    for {n, text} <- notes, do: {:ok, _} = Plans.put_note(scope, plan, n, text)

    %{name: child.name, note: "The ABCs of Sleep on night 9, #{length(rows)} entries"}
  end

  # Wakings by plan night: five on night 1 down to one on night 8.
  defp sigrid_wakings(n) do
    all = [
      %{at: 130, mins: 12, feed: nil},
      %{at: 190, mins: 15, feed: 150},
      %{at: 300, mins: 12, feed: nil},
      %{at: 440, mins: 18, feed: 150},
      %{at: 520, mins: 10, feed: nil}
    ]

    count = max(6 - n, 1)

    all
    |> Enum.take(count)
    |> Enum.with_index()
    |> Enum.map(fn {w, i} ->
      # Night feeds follow the weaning table: lower each night, gone from night 5.
      feed = if w.feed && n < 5, do: max(150 - (n - 1) * 35, 20), else: nil
      %{w | feed: if(i < 2, do: feed, else: nil), at: w.at + jit(0, 15)}
    end)
  end

  defp sigrid_night(n) do
    cry = [118, 74, 55, 40, 27, 21, 14, 9] |> Enum.at(n - 1)

    %{
      # Crying across the night; just over half of it at bedtime.
      cry: cry,
      settle: round(cry * 0.55),
      pop_ins: [[5, 15, 30, 45], [5, 15, 30], [5, 15], [5], [5], [], [], []] |> Enum.at(n - 1),
      wakings: [4, 3, 2, 2, 1, 1, 1, 0] |> Enum.at(n - 1)
    }
  end

  ## The pattern generator ---------------------------------------------------------------------

  # Builds every entry for `cfg`'s child: for each day its feeds, diapers and naps,
  # and for each evening the night. Rows after `now` are dropped, and a sleep that
  # is still going is left running.
  defp generate(cfg, user, partner, now, opts) do
    today = local_today(now)
    evening = evening_date(now)
    plan_nights = Map.new(opts[:plan_nights] || [])
    plan_started = opts[:plan_started]
    users = [user, partner]

    # Each day's numbers are drawn once, so the night that ends a day and the
    # morning that starts the next agree about when they woke.
    days =
      for offset <- -cfg.days..1//1,
          date = Date.add(today, offset),
          j = Date.diff(date, evening),
          into: %{} do
        wake = cfg.wake.(j)

        {date,
         %{
           j: j,
           wake: wake,
           bed: cfg.bed.(j),
           settle: cfg.settle.(j),
           naps: cfg.naps.(j, wake),
           wakings: cfg.wakings.(j),
           assist: cfg.assist.(j)
         }}
      end

    rows =
      for offset <- -(cfg.days - 1)..0//1,
          date = Date.add(today, offset),
          row <-
            day_rows(cfg, date, days, users) ++
              night_rows(cfg, date, days, plan_nights, plan_started, users) do
        row
      end

    rows
    |> Enum.filter(&(DateTime.compare(&1.started_at, now) != :gt))
    |> Enum.map(fn row ->
      if row.ended_at && DateTime.compare(row.ended_at, now) == :gt,
        do: %{row | ended_at: nil},
        else: row
    end)
  end

  defp day_rows(cfg, date, days, users) do
    %{j: j, wake: wake, bed: bed} = day = days[date]
    user = Enum.at(users, abs(j) |> rem(2))

    # Naps, each after its wake window.
    {naps, _} =
      day.naps
      |> Enum.with_index(1)
      |> Enum.map_reduce(wake, fn {{window, length}, ordinal}, from ->
        start = from + window + jit(0, 6)
        finish = start + length
        {{ordinal, start, finish}, finish}
      end)

    nap_rows =
      for {ordinal, start, finish} <- naps, start < bed - 40 do
        data =
          %{"location" => cfg.nap_place.(j, ordinal)}
          |> maybe_put("cue", if(:rand.uniform() < 0.6, do: pick(cfg.cues)))
          |> put_assist(day.assist, 0.7)

        row(cfg.child, user, :sleep, at(date, start), at(date, finish), data)
      end

    feed_times =
      Stream.iterate(wake + 10, &(&1 + 175 + jit(0, 12)))
      |> Enum.take_while(&(&1 < bed - 45))

    feeds =
      for t <- feed_times ++ [bed - 30] do
        row(cfg.child, user, :feeding, at(date, t), at(date, t), %{
          "bottle_contents" => pick([{"formula", 80}, {"expressed", 20}]),
          "amount_ml" => cfg.feed_ml + jit(-10, 10)
        })
      end

    diapers =
      for t <- feed_times ++ [bed - 40], :rand.uniform() < 0.8 do
        row(cfg.child, user, :diaper, at(date, t + 10), at(date, t + 10), diaper())
      end

    feeds ++ diapers ++ nap_rows
  end

  defp night_rows(cfg, date, days, plan_nights, plan_started, users) do
    %{j: j, bed: put_down} = day = days[date]
    plan_n = plan_started && Date.diff(date, plan_started) + 1
    spec = if plan_n && plan_n >= 1, do: Map.get(plan_nights, plan_n)

    settle =
      cond do
        spec && spec[:settle] -> spec.settle
        spec && spec[:cry] -> spec.cry
        true -> day.settle
      end

    asleep = put_down + settle
    morning = 1440 + days[Date.add(date, 1)].wake
    wakings = waking_list(day, spec)
    user = Enum.at(users, abs(j) |> rem(2))

    {segments, last_start} =
      Enum.reduce(wakings, {[], asleep}, fn w, {acc, from} ->
        start = asleep + w.at
        finish = start + w.mins
        {[{from, max(start, from + 20)} | acc], max(finish, start)}
      end)

    segments = Enum.reverse([{last_start, morning} | segments])

    sleeps =
      for {{from, to}, i} <- Enum.with_index(segments), to > from do
        data =
          if i == 0 do
            %{"location" => "crib", "cue" => "ready"}
            |> put_assist(day.assist, 1.0)
            |> then(fn d ->
              if is_integer(settle),
                do: Map.put(d, "settle_minutes", settle_bucket(settle)),
                else: d
            end)
          else
            %{"location" => "crib"}
          end

        row(cfg.child, user, :sleep, at(date, from), at(date, to), data)
      end

    feeds =
      for w <- wakings, w.feed do
        t = asleep + w.at + 4

        row(cfg.child, user, :feeding, at(date, t), at(date, t), %{
          "bottle_contents" => "formula",
          "amount_ml" => w.feed
        })
      end

    sleeps ++ feeds
  end

  # The wakings of a night: from the spec on a plan night, else the pattern's.
  defp waking_list(day, %{wakings: wakings}) when is_list(wakings) do
    # SLIP wakings are `{at, mins, visits}` triples.
    wakings
    |> Enum.map(fn {at, mins, _visits} -> %{at: at, mins: mins, feed: nil} end)
    |> Enum.sort_by(& &1.at)
    |> case do
      [] -> Enum.sort_by(day.wakings, & &1.at)
      list -> list
    end
  end

  # The ABCs give a count of wakings.
  defp waking_list(day, %{wakings: count}) when is_integer(count),
    do: day.wakings |> Enum.take(count) |> Enum.sort_by(& &1.at)

  defp waking_list(day, _spec), do: Enum.sort_by(day.wakings, & &1.at)

  ## Plan nights as night-mode wakings --------------------------------------------------------

  # SWAP: the put-down and how long it took, with a few times in.
  defp swap_night(child, plan, n, spec, user, partner) do
    started = bedtime_at(child, plan, n, spec.settle)
    asleep = DateTime.add(started, spec.settle * 60, :second)

    events =
      [Checkins.event("cry", DateTime.add(started, 60, :second))] ++
        for i <- 1..spec.went_in//1 do
          Checkins.event("pop_in", DateTime.add(started, (i * 6 + 2) * 60, :second))
        end ++ [Checkins.event("asleep", asleep)]

    user_id = if(rem(n, 2) == 0, do: partner.id, else: user.id)
    insert_checkin_wake(child, plan, :bedtime, started, asleep, events, user_id)

    # The two feed wakings of the night, each with a time in.
    for {minutes, mins_awake} <- [{176, 20}, {402, 18}] do
      from = DateTime.add(asleep, minutes * 60, :second)
      until = DateTime.add(from, mins_awake * 60, :second)

      events = [
        Checkins.event("cry", from),
        Checkins.event("pop_in", DateTime.add(from, 7 * 60, :second)),
        Checkins.event("asleep", until)
      ]

      insert_checkin_wake(child, plan, :waking, from, until, events, user_id)
    end
  end

  # SLIP: bedtime with its visits, then the night's wakings.
  defp slip_wakes(child, plan, n, spec, user, partner) do
    started = bedtime_at(child, plan, n, spec.cry)

    visits =
      for m <- spec.visits, do: Checkins.event("pop_in", DateTime.add(started, m * 60, :second))

    asleep = DateTime.add(started, spec.cry * 60, :second)
    events = [Checkins.event("cry", started)] ++ visits ++ [Checkins.event("asleep", asleep)]
    user_id = if(rem(n, 2) == 0, do: partner.id, else: user.id)

    insert_checkin_wake(child, plan, :bedtime, started, asleep, events, user_id)

    for {at, mins, minutes} <- spec.wakings do
      from = DateTime.add(asleep, at * 60, :second)
      until = DateTime.add(from, mins * 60, :second)

      events =
        [Checkins.event("cry", from)] ++
          for(m <- minutes, do: Checkins.event("pop_in", DateTime.add(from, m * 60, :second))) ++
          [Checkins.event("calm", DateTime.add(from, max(mins - 4, 1) * 60, :second))] ++
          [Checkins.event("asleep", until)]

      insert_checkin_wake(child, plan, :waking, from, until, events, user_id)
    end
  end

  # ABCs: pop-ins at 5, 15 and 30 minutes, and a few wakings of the night.
  defp abcs_wakes(child, plan, n, spec, user, partner) do
    started = bedtime_at(child, plan, n, spec.settle)
    asleep = DateTime.add(started, spec.settle * 60, :second)
    user_id = if(rem(n, 2) == 0, do: partner.id, else: user.id)

    visits =
      for m <- spec.pop_ins, m < spec.settle do
        Checkins.event("pop_in", DateTime.add(started, m * 60, :second))
      end

    events = [Checkins.event("cry", started)] ++ visits ++ [Checkins.event("asleep", asleep)]
    insert_checkin_wake(child, plan, :bedtime, started, asleep, events, user_id)

    # The rest of the night's crying is spread over its wakings.
    each = max(div(spec.cry - spec.settle, max(spec.wakings, 1)), 2)

    for {at, i} <- Enum.with_index(Enum.take([130, 190, 300, 440, 520], spec.wakings), 1) do
      from = DateTime.add(asleep, at * 60, :second)
      until = DateTime.add(from, each * 60, :second)

      events =
        [Checkins.event("cry", from)] ++
          if(each > 5 and i == 1,
            do: [Checkins.event("pop_in", DateTime.add(from, 5 * 60, :second))],
            else: []
          ) ++ [Checkins.event("asleep", until)]

      insert_checkin_wake(child, plan, :waking, from, until, events, user_id)
    end
  end

  defp insert_checkin_wake(child, plan, kind, started, ended, events, user_id) do
    insert_wake(child, %{
      method: :abcs,
      kind: kind,
      plan_id: plan.id,
      started_at: started,
      step_started_at: started,
      ended_at: ended,
      outcome: :settled,
      cry_seconds: Checkins.state(events, ended).cry_seconds,
      events: events,
      started_by_id: user_id
    })
  end

  # When night `n` of the plan was put down: `settle` minutes before the first
  # sleep of that evening.
  defp bedtime_at(child, plan, n, settle) do
    date = Plans.night_date(plan, n)
    after_dinner = at(date, 18 * 60 + 15)
    late = at(date, 1440 + 90)

    first =
      Repo.one(
        from(e in Entry,
          where:
            e.child_id == ^child.id and e.type == :sleep and e.started_at >= ^after_dinner and
              e.started_at <= ^late,
          order_by: [asc: e.started_at],
          limit: 1
        )
      )

    DateTime.add(first.started_at, -settle * 60, :second)
  end

  ## Small things -------------------------------------------------------------------------------

  defp insert_wake(child, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    base = %{
      child_id: child.id,
      step: 0,
      kind: :waking,
      events: [],
      inserted_at: now,
      updated_at: now
    }

    Repo.insert_all(NightWake, [Map.merge(base, attrs)])
  end

  defp insert_rows(rows) do
    rows |> Enum.chunk_every(500) |> Enum.each(&Repo.insert_all(Entry, &1))
  end

  defp row(child, user, type, started_at, ended_at, data) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      child_id: child.id,
      logged_by_id: user.id,
      type: type,
      started_at: started_at,
      ended_at: ended_at,
      data: data,
      note: nil,
      inserted_at: now,
      updated_at: now
    }
  end

  defp diaper do
    case pick([{"pee", 55}, {"mixed", 25}, {"poo", 20}]) do
      "pee" ->
        %{"kind" => "pee"}

      kind ->
        %{
          "kind" => kind,
          "color" => "yellow",
          "consistency" => pick([{"seedy", 60}, {"loose", 40}])
        }
    end
  end

  defp weigh_ins(child, user, spec, now) do
    today = local_today(now)
    stamp = DateTime.truncate(now, :second)

    rows =
      for {offset, z} <- spec,
          date = Date.add(today, offset),
          Date.compare(date, child.birth_date) != :lt do
        weight = Percentiles.value_at_z(child, :weight, z, date) || 6000.0
        height = Percentiles.value_at_z(child, :length, z, date) || 60.0

        %{
          child_id: child.id,
          logged_by_id: user.id,
          measured_at: child |> Child.day_bounds(date) |> elem(0) |> DateTime.truncate(:second),
          weight_g: Float.round(weight / 10) * 10.0,
          height_cm: Float.round(height, 1),
          note: nil,
          inserted_at: stamp,
          updated_at: stamp
        }
      end

    Repo.insert_all(Measurement, rows)
  end

  defp checks(today, ids),
    do: ids |> Enum.uniq() |> Map.new(&{&1, Date.to_iso8601(Date.add(today, -2))})

  # Assist levels climbing from `from` to `to` over `days` days, with noise: {level, settle}.
  defp level_for(k, days, from, to) do
    progress = (k + days) / days
    level = from + (to - from) * progress + (:rand.uniform() - 0.5) * 1.6
    level = level |> round() |> max(1) |> min(9)
    {level, max(round(40 - progress * 28 + jit(-6, 8)), 3)}
  end

  defp put_assist(data, {level, settle}, chance) do
    if :rand.uniform() < chance do
      data |> Map.put("assist", level) |> Map.put("settle_minutes", settle_bucket(settle))
    else
      data
    end
  end

  # The time-to-settle choices the app offers.
  defp settle_bucket(minutes) do
    cond do
      minutes <= 5 -> 5
      minutes <= 10 -> 10
      minutes <= 20 -> 20
      minutes <= 30 -> 30
      true -> 45
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp local_today(now), do: now |> DateTime.shift_zone!(@tz) |> DateTime.to_date()

  # The evening a night mode started "now" would belong to: before midday it's
  # still last night.
  defp evening_date(now) do
    local = DateTime.shift_zone!(now, @tz)
    if local.hour < 12, do: Date.add(DateTime.to_date(local), -1), else: DateTime.to_date(local)
  end

  # A local wall-clock time as UTC. Minutes can run past midnight. Times that fall
  # in a clock change take the first reading.
  defp at(date, minutes) do
    {date, minutes} =
      if minutes >= 1440, do: {Date.add(date, 1), minutes - 1440}, else: {date, minutes}

    time = Time.new!(div(minutes, 60), rem(minutes, 60), 0)

    local =
      case DateTime.new(date, time, @tz) do
        {:ok, dt} -> dt
        {:ambiguous, first, _second} -> first
        {:gap, _before, after_gap} -> after_gap
      end

    local |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
  end

  defp jit(lo, hi), do: lo + :rand.uniform(hi - lo + 1) - 1

  defp pick(weighted) when is_list(weighted) do
    total = Enum.reduce(weighted, 0, fn {_v, w}, acc -> acc + w end)
    target = :rand.uniform() * total

    Enum.reduce_while(weighted, target, fn {value, weight}, acc ->
      if acc <= weight, do: {:halt, value}, else: {:cont, acc - weight}
    end)
  end
end
