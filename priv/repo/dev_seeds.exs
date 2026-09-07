# Local-dev seed data.
#
#     mix seed.dev
#     # or: mix run priv/repo/dev_seeds.exs
#
# Creates (or reuses) a magic-link user `hello@johabackman.com` / "Johan Backman"
# and two children on his shared log:
#
#   * Astrid — one week old. A realistic newborn week: bottle feeds every couple
#     of hours (small colostrum-era amounts growing day by day), a dozen-ish
#     diapers a day (meconium → transitional → seedy yellow), and the short,
#     scattered sleeps of a newborn. Predictions here lean on the age prior —
#     no circadian rhythm yet.
#
#   * Otto — about five months old, on a settled three-nap routine, so the sleep
#     predictor has something real to work with. Three weeks of age-appropriate
#     sleep with day-to-day jitter, and a short first nap today so bedtime is
#     pulled earlier. Every historical wake is replayed through
#     `Trygg.Reports.PredictionLedger`, so the ledger holds real reconciled
#     predictions (within ~10 min) and the Reports outlook reports its recent
#     accuracy. Set `@predictor_transition_days_ago` to ~6 to make the "nap
#     schedule looks like it's shifting" signal fire instead.
#
# If the current wall-clock lands mid-nap for either child, that nap is left
# running so the dashboard's live sleep timer has something to show.
#
# Re-running wipes both children's entries (and Otto's prediction ledger) and
# regenerates, so it's safe to run repeatedly. The RNG is seeded, so the shape
# is stable.

defmodule Trygg.DevSeeds do
  import Ecto.Query

  alias Trygg.{Accounts, Families, Repo}
  alias Trygg.Accounts.Scope
  alias Trygg.Log.Entry
  alias Trygg.Reports.{Prediction, PredictionLedger}

  @email "hello@johabackman.com"
  @first_name "Johan"
  @last_name "Backman"
  @child_name "Astrid"
  @tz "America/Los_Angeles"

  # Otto — the settled routine the sleep predictor is built for.
  @predictor_name "Otto"
  @predictor_age_days 150
  @predictor_history_days 21
  # Days ago the three-nap → two-nap drop happens. 0 = never (a steady
  # three-nap routine, the default). Bump to ~6 to see the "nap schedule looks
  # like it's shifting" signal fire.
  @predictor_transition_days_ago 0

  def run do
    :rand.seed(:exsss, {20_260_901, 7, 24})

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    birth = DateTime.add(now, -7 * 24 * 3600, :second)

    user = upsert_user(now)
    scope = Scope.for_user(user)
    child = upsert_child(scope, birth)

    {deleted, _} = Repo.delete_all(from(e in Entry, where: e.child_id == ^child.id))

    rows =
      build_week(child, user, birth, now)
      |> Enum.filter(&(DateTime.compare(&1.started_at, now) != :gt))

    {inserted, _} = Repo.insert_all(Entry, rows)

    otto = seed_predictor_child(scope, user, now)

    IO.puts("""

    Seeded local dev data:
      user   #{user.email}  (#{user.first_name} #{user.last_name}, magic-link, confirmed)
      child  #{child.name}  (female, born #{DateTime.shift_zone!(birth, @tz) |> Calendar.strftime("%Y-%m-%d %H:%M")} #{@tz}, 1 week old)
      log    #{inserted} entries over 7 days#{if deleted > 0, do: "  (replaced #{deleted} previous)", else: ""}
      running nap: #{if Enum.any?(rows, &is_nil(&1.ended_at)), do: "yes — dashboard timer is live", else: "no"}
      child  #{otto.name}  (~5 months old, settled routine; #{@predictor_history_days}d of sleep, prediction ledger filled)

    Sign in at /users/log-in with #{user.email} (grab the magic link from the server log).
    The sleep predictor is live on #{otto.name}'s Home card and Reports → Trends → Today's outlook.
    """)
  end

  # --- user & child ---------------------------------------------------------

  defp upsert_user(now) do
    case Accounts.get_user_by_email(@email) do
      nil ->
        {:ok, user} =
          Accounts.register_user(%{
            email: @email,
            first_name: @first_name,
            last_name: @last_name
          })

        user
        |> Ecto.Changeset.change(confirmed_at: now, unit_system: :metric)
        |> Repo.update!()

      %Accounts.User{} = user ->
        user
    end
  end

  defp upsert_child(scope, birth) do
    local_birth = DateTime.shift_zone!(birth, @tz)

    attrs = %{
      name: @child_name,
      birth_date: DateTime.to_date(local_birth),
      birth_time: local_birth |> DateTime.to_time() |> Time.truncate(:second),
      sex: :female,
      timezone: @tz
    }

    case Enum.find(Families.list_children(scope), &(&1.name == @child_name)) do
      nil ->
        {:ok, child} = Families.create_child(scope, attrs)
        child

      existing ->
        {:ok, child} = Families.update_child(scope, existing, attrs)
        child
    end
  end

  # --- the week ------------------------------------------------------------

  # Walk forward from the first feed after birth: feed on waking, a diaper or
  # two per cycle, an awake window, then a sleep. Stop at `now`, leaving the
  # final sleep running if we're mid-nap.
  defp build_week(child, user, birth, now) do
    first_feed = DateTime.add(birth, 22 * 60, :second)
    cycle(child, user, birth, now, first_feed, [])
  end

  defp cycle(child, user, birth, now, t, acc) do
    if DateTime.compare(t, now) != :lt do
      Enum.reverse(acc)
    else
      age = age_days(t, birth)
      hour = local_hour(t)
      night? = hour >= 21 or hour < 6

      acc = [feed_row(child, user, t, age) | acc]

      acc =
        if chance(0.7),
          do: [diaper_row(child, user, later(t, 1, 12), age) | acc],
          else: acc

      awake = if night?, do: rand_between(20, 45), else: rand_between(30, 95)
      sleep_start = later(t, awake, awake)

      acc =
        if chance(0.3),
          do: [diaper_row(child, user, later(t, div(awake, 2), div(awake, 2)), age) | acc],
          else: acc

      cluster? = hour in 18..23 and chance(0.45)

      sleep_len =
        cond do
          cluster? -> rand_between(15, 45)
          night? -> rand_between(100, 185)
          true -> rand_between(35, 135)
        end

      wake_at = later(sleep_start, sleep_len, sleep_len)

      cond do
        # The awake window already ran past now — she's awake, no nap to log.
        DateTime.compare(sleep_start, now) != :lt ->
          Enum.reverse(acc)

        # Mid-nap right now — leave it running for the live dashboard timer.
        DateTime.compare(wake_at, now) != :lt ->
          [sleep_row(child, user, sleep_start, nil, night?) | acc] |> Enum.reverse()

        true ->
          acc = [sleep_row(child, user, sleep_start, wake_at, night?) | acc]
          cycle(child, user, birth, now, wake_at, acc)
      end
    end
  end

  # --- rows -------------------------------------------------------------------

  defp feed_row(child, user, at, age) do
    data = %{
      "bottle_contents" => pick([{"formula", 82}, {"expressed", 18}]),
      "amount_ml" => feed_amount(age)
    }

    base_row(child, user, :feeding, at, at, data, maybe_note(:feeding))
  end

  defp diaper_row(child, user, at, age) do
    base_row(child, user, :diaper, at, at, diaper_data(age), maybe_note(:diaper))
  end

  defp sleep_row(child, user, start_at, end_at, night?) do
    loc =
      if night? do
        pick([{"bassinet", 78}, {"crib", 17}, {"contact", 5}])
      else
        pick([{"contact", 40}, {"bassinet", 33}, {"stroller", 15}, {"crib", 12}])
      end

    note = if is_nil(end_at), do: nil, else: maybe_note(:sleep)
    base_row(child, user, :sleep, start_at, end_at, %{"location" => loc}, note)
  end

  defp base_row(child, user, type, started_at, ended_at, data, note) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      child_id: child.id,
      logged_by_id: user.id,
      type: type,
      started_at: started_at,
      ended_at: ended_at,
      data: data,
      note: note,
      inserted_at: now,
      updated_at: now
    }
  end

  # --- newborn shape -------------------------------------------------------

  defp feed_amount(age) do
    base = 15 + age * 9.0
    jitter = (:rand.uniform() - 0.5) * 18
    (base + jitter) |> max(15.0) |> min(95.0) |> round_step(5)
  end

  # Stool colour/consistency track the classic newborn progression: tarry black
  # meconium for the first couple of days, khaki-green transitional, then seedy
  # yellow once feeding is established. Plain pee diapers carry neither.
  defp diaper_data(age) do
    kind =
      cond do
        age < 2.0 -> pick([{"poo", 50}, {"mixed", 38}, {"pee", 12}])
        age < 4.0 -> pick([{"mixed", 42}, {"poo", 30}, {"pee", 28}])
        true -> pick([{"pee", 55}, {"mixed", 25}, {"poo", 20}])
      end

    if kind == "pee" do
      %{"kind" => "pee"}
    else
      {color, consistency} =
        cond do
          age < 2.0 ->
            {pick([{"black", 60}, {"dark green", 40}]), pick([{"sticky", 55}, {"tarry", 45}])}

          age < 4.0 ->
            {pick([{"green", 50}, {"brown", 35}, {"yellow", 15}]),
             pick([{"seedy", 45}, {"loose", 40}, {"sticky", 15}])}

          true ->
            {pick([{"yellow", 82}, {"green", 18}]),
             pick([{"seedy", 55}, {"loose", 30}, {"runny", 15}])}
        end

      %{"kind" => kind, "color" => color, "consistency" => consistency}
    end
  end

  defp maybe_note(:feeding) do
    maybe(0.12, [
      "Big spit-up after this one",
      "Took it fast — really hungry",
      "Dozed off halfway, had to rouse her",
      "Cluster feeding this evening",
      "Fussy, needed a few tries to latch onto the bottle"
    ])
  end

  defp maybe_note(:sleep) do
    maybe(0.1, [
      "Went down easy",
      "Fought it for ages",
      "Woke once, resettled with the pacifier",
      "Contact nap — would not go in the bassinet"
    ])
  end

  defp maybe_note(:diaper) do
    maybe(0.08, [
      "Blowout — full change of clothes",
      "Slept right through the change",
      "Bit of redness starting, added cream"
    ])
  end

  # --- helpers -----------------------------------------------------------

  defp age_days(t, birth), do: DateTime.diff(t, birth, :second) / 86_400.0

  defp local_hour(t), do: t |> DateTime.shift_zone!(@tz) |> Map.fetch!(:hour)

  # A jittered offset in minutes: somewhere in [lo, hi], then to the second.
  defp later(t, lo, hi) do
    mins = rand_between(lo, hi)
    secs = :rand.uniform(60) - 1
    DateTime.add(t, mins * 60 + secs, :second)
  end

  defp rand_between(same, same), do: same
  defp rand_between(lo, hi) when hi > lo, do: lo + :rand.uniform(hi - lo + 1) - 1
  defp rand_between(lo, hi), do: rand_between(hi, lo)

  defp chance(p), do: :rand.uniform() < p

  defp maybe(p, choices), do: if(chance(p), do: Enum.random(choices), else: nil)

  defp round_step(n, step), do: (Float.round(n / step) * step) |> trunc()

  defp pick(weighted) do
    total = Enum.reduce(weighted, 0, fn {_v, w}, acc -> acc + w end)
    target = :rand.uniform() * total

    Enum.reduce_while(weighted, target, fn {value, weight}, acc ->
      if acc <= weight, do: {:halt, value}, else: {:cont, acc - weight}
    end)
  end

  # --- Otto: the settled routine for the sleep predictor -----------------

  # An age-appropriate day: morning wake, then a run of naps separated by
  # age-typical wake windows, then bedtime. All in minutes from local midnight.
  # `three_nap?` toggles the pre / post nap-transition shape.
  defp predictor_model(true) do
    %{wake: 6 * 60 + 45, ww: [90, 130, 160, 175], nap: [70, 75, 40]}
  end

  defp predictor_model(false) do
    %{wake: 6 * 60 + 45, ww: [165, 205, 220], nap: [85, 75]}
  end

  # Steady three-nap routine unless a transition is configured.
  defp predictor_three_nap?(days_ago) do
    @predictor_transition_days_ago <= 0 or days_ago >= @predictor_transition_days_ago
  end

  defp upsert_predictor_child(scope, now) do
    birth = DateTime.add(now, -@predictor_age_days * 24 * 3600, :second)
    local_birth = DateTime.shift_zone!(birth, @tz)

    attrs = %{
      name: @predictor_name,
      birth_date: DateTime.to_date(local_birth),
      birth_time: ~T[04:10:00],
      sex: :male,
      timezone: @tz,
      # early day start so the first short wake window is unambiguously daytime
      day_start: ~T[06:00:00],
      night_start: ~T[19:00:00]
    }

    case Enum.find(Families.list_children(scope), &(&1.name == @predictor_name)) do
      nil -> Families.create_child(scope, attrs) |> ok!()
      existing -> Families.update_child(scope, existing, attrs) |> ok!()
    end
  end

  defp seed_predictor_child(scope, user, now) do
    child = upsert_predictor_child(scope, now)

    Repo.delete_all(from(e in Entry, where: e.child_id == ^child.id))
    Repo.delete_all(from(p in Prediction, where: p.child_id == ^child.id))

    today = child |> local_now(now) |> DateTime.to_date()
    dates = for i <- @predictor_history_days..1//-1, do: Date.add(today, -i)

    # Walk the days in order, carrying each day's bedtime forward so the next
    # morning's overnight block starts exactly where the last wake window ended.
    {day_blocks, last_bed} =
      Enum.reduce(dates, {[], nil}, fn d, {acc, prev_bed} ->
        model = predictor_model(predictor_three_nap?(day_index_from_today(today, d)))
        wake_min = model.wake + rand_between(-12, 12)
        wake_dt = at_local(child, d, wake_min)
        night_start = prev_bed || at_local(child, Date.add(d, -1), model.wake + 12 * 60)

        {naps, bed_min} = full_day_naps(child, d, model, wake_min)
        night = %{s: night_start, e: wake_dt, wake?: true}

        {acc ++ [night | naps], at_local(child, d, bed_min)}
      end)

    blocks =
      (day_blocks ++ partial_today(child, today, now, last_bed))
      |> Enum.sort_by(& &1.s, DateTime)

    # Don't record predictions from the first few days — they'd only ever be the
    # age prior and would drag the accuracy summary down for weeks.
    ledger_from = at_local(child, Date.add(today, -(@predictor_history_days - 5)), 0)

    # Insert a block, and on every real wake replay it through the ledger — so
    # the prediction is always built from the log as it stood at that moment.
    Enum.each(blocks, fn b ->
      Repo.insert_all(Entry, [sleep_block_row(child, user, b)])

      if b.wake? and not is_nil(b.e) and DateTime.compare(b.e, ledger_from) == :gt do
        PredictionLedger.track(child, DateTime.add(b.e, 1, :second))
      end
    end)

    child
  end

  # A full past day's naps as {start, end} wake blocks, plus the bedtime (the
  # last nap end + the final wake window), all in minutes from local midnight.
  # History days follow the routine with modest jitter so the predictor has a
  # clean pattern to lock onto; the interesting "short day" is only today.
  defp full_day_naps(child, date, model, wake_min) do
    {naps, cursor} =
      model.nap
      |> Enum.with_index()
      |> Enum.reduce({[], wake_min}, fn {dur, i}, {acc, t} ->
        start = t + Enum.at(model.ww, i) + rand_between(-9, 9)
        finish = start + max(dur + rand_between(-9, 9), 15)

        block = %{s: at_local(child, date, start), e: at_local(child, date, finish), wake?: true}
        {[block | acc], finish}
      end)

    bed_min = cursor + List.last(model.ww) + rand_between(-12, 12)
    {Enum.reverse(naps), bed_min}
  end

  # Today up to `now`: last night's stretch, then the naps that have already
  # happened (the last one left running if we're mid-nap), with a deliberately
  # short first nap so the day is trailing the usual daytime sleep.
  defp partial_today(child, today, now, last_bed) do
    model = predictor_model(predictor_three_nap?(0))
    wake_min = model.wake + rand_between(-8, 8)

    night_start =
      last_bed ||
        at_local(child, Date.add(today, -1), model.wake + 12 * 60 + rand_between(-15, 25))

    wake_dt = at_local(child, today, wake_min)

    if DateTime.compare(wake_dt, now) != :lt do
      # still asleep for the night
      [%{s: night_start, e: nil, wake?: false}]
    else
      night = %{s: night_start, e: wake_dt, wake?: true}
      [night | partial_today_naps(child, today, now, model, wake_min)]
    end
  end

  defp partial_today_naps(child, today, now, model, wake_min) do
    {blocks, _cursor, _stop} =
      model.nap
      |> Enum.with_index()
      |> Enum.reduce({[], wake_min, false}, fn
        _pair, {acc, t, true} ->
          {acc, t, true}

        {dur, i}, {acc, t, false} ->
          start = t + Enum.at(model.ww, i) + rand_between(-10, 10)
          # first nap of the day runs short on purpose
          len = if i == 0, do: round(dur * 0.45), else: dur + rand_between(-10, 10)
          finish = start + max(len, 12)

          start_dt = at_local(child, today, start)
          finish_dt = at_local(child, today, finish)

          cond do
            DateTime.compare(start_dt, now) != :lt ->
              {acc, t, true}

            DateTime.compare(finish_dt, now) != :lt ->
              {[%{s: start_dt, e: nil, wake?: false} | acc], finish, true}

            true ->
              {[%{s: start_dt, e: finish_dt, wake?: true} | acc], finish, false}
          end
      end)

    Enum.reverse(blocks)
  end

  defp sleep_block_row(child, user, %{s: s, e: e}) do
    night? = local_hour(s) >= 19 or local_hour(s) < 6

    loc =
      if night?,
        do: pick([{"bassinet", 60}, {"crib", 38}, {"contact", 2}]),
        else: pick([{"crib", 45}, {"bassinet", 30}, {"contact", 15}, {"stroller", 10}])

    base_row(child, user, :sleep, s, e, %{"location" => loc}, nil)
  end

  # --- small helpers ----------------------------------------------------

  defp ok!({:ok, value}), do: value

  defp local_now(child, now), do: DateTime.shift_zone!(now, child.timezone)

  defp at_local(child, %Date{} = date, minutes) do
    minutes = max(round(minutes), 0)
    extra_days = div(minutes, 24 * 60)
    mins = rem(minutes, 24 * 60)
    time = Time.new!(div(mins, 60), rem(mins, 60), 0)
    Trygg.Families.Child.at_local(child, Date.add(date, extra_days), time)
  end

  defp day_index_from_today(today, date), do: Date.diff(today, date)
end

Trygg.DevSeeds.run()
