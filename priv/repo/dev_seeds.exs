# Local-dev seed data.
#
#     mix seed.dev
#     # or: mix run priv/repo/dev_seeds.exs
#
# Creates (or reuses) a magic-link user `hello@johabackman.com` / "Johan Backman"
# and a two-month-old daughter, Astrid, then fills her shared log with a
# realistic run of infant life: bottle feeds every couple of hours (small
# colostrum-era amounts growing into full ~150 ml bottles), a handful of diapers
# a day (meconium → transitional → seedy yellow), and sleeps that start short and
# scattered and consolidate into real night stretches as she matures. If the
# current wall-clock lands mid-nap, that nap is left running so the dashboard's
# live sleep timer has something to show.
#
# Her Vitals tab gets a birth measurement, the day-4 dip, and well-child
# height/weight checks through two months, all riding a healthy CDC percentile.
#
# Re-running wipes Astrid's existing entries and measurements and regenerates, so
# it's safe to run repeatedly. The RNG is seeded, so the shape is stable.

defmodule Trygg.DevSeeds do
  import Ecto.Query

  alias Trygg.{Accounts, Families, Repo}
  alias Trygg.Accounts.Scope
  alias Trygg.Families.Child
  alias Trygg.Growth.Measurement
  alias Trygg.Growth.Percentiles
  alias Trygg.Log.Entry

  @email "hello@johabackman.com"
  @first_name "Johan"
  @last_name "Backman"
  @child_name "Astrid"
  @tz "America/Los_Angeles"

  # How old the seeded child is. A couple of months in gives the Vitals tab a
  # real growth curve — birth weight, the newborn dip, and a handful of
  # well-child checks — instead of a lone birth-day point.
  @age_days 63

  def run do
    :rand.seed(:exsss, {20_260_901, 7, 24})

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    birth = DateTime.add(now, -@age_days * 24 * 3600, :second)

    user = upsert_user(now)
    scope = Scope.for_user(user)
    child = upsert_child(scope, birth)

    {deleted, _} = Repo.delete_all(from(e in Entry, where: e.child_id == ^child.id))

    {deleted_growth, _} =
      Repo.delete_all(from(m in Measurement, where: m.child_id == ^child.id))

    rows =
      build_history(child, user, birth, now)
      |> Enum.filter(&(DateTime.compare(&1.started_at, now) != :gt))

    {inserted, _} = Repo.insert_all(Entry, rows)

    growth_rows = build_growth(child, user, birth, now)
    {inserted_growth, _} = Repo.insert_all(Measurement, growth_rows)

    weeks = div(@age_days, 7)

    IO.puts("""

    Seeded local dev data:
      user   #{user.email}  (#{user.first_name} #{user.last_name}, magic-link, confirmed)
      child  #{child.name}  (female, born #{DateTime.shift_zone!(birth, @tz) |> Calendar.strftime("%Y-%m-%d %H:%M")} #{@tz}, #{weeks} weeks old)
      log    #{inserted} entries over #{@age_days} days#{if deleted > 0, do: "  (replaced #{deleted} previous)", else: ""}
      vitals #{inserted_growth} height/weight measurements#{if deleted_growth > 0, do: "  (replaced #{deleted_growth} previous)", else: ""}
      running nap: #{if Enum.any?(rows, &is_nil(&1.ended_at)), do: "yes — dashboard timer is live", else: "no"}

    Sign in at /users/log-in with #{user.email} (grab the magic link from the server log).
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

  # --- the log ------------------------------------------------------------

  # Walk forward from the first feed after birth: feed on waking, a diaper or
  # two per cycle, an awake window, then a sleep. Stop at `now`, leaving the
  # final sleep running if we're mid-nap.
  defp build_history(child, user, birth, now) do
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

      # Awake windows stretch through the first weeks; night wakings stay brief.
      grown = min(max(age - 14.0, 0.0), 60.0)

      awake =
        if night? do
          rand_between(20, 45)
        else
          lo = 30 + trunc(grown * 0.7)
          rand_between(lo, lo + 65)
        end

      sleep_start = later(t, awake, awake)

      acc =
        if chance(0.3),
          do: [diaper_row(child, user, later(t, div(awake, 2), div(awake, 2)), age) | acc],
          else: acc

      cluster? = hour in 18..23 and chance(0.45)

      sleep_len =
        cond do
          cluster? -> rand_between(15, 45)
          night? -> rand_between(100 + trunc(grown * 1.5), 185 + trunc(grown * 2.4))
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

  # --- growth measurements ----------------------------------------------

  # A birth reading, the day-4 nadir of the newborn dip, then well-child checks
  # at roughly 2 weeks, 1 month, 6 weeks and 2 months. Weights and lengths ride
  # a gently rising CDC z-score with a little scale noise, so the Vitals tab
  # shows a healthy climb with sane percentiles and gain rates.
  defp build_growth(child, user, birth, now) do
    birth_date = birth |> DateTime.shift_zone!(@tz) |> DateTime.to_date()

    # {days after birth, weight spec, height spec or nil, note or nil}
    plan = [
      {0, {:z, 0.25}, {:z, 0.1}, "Birth"},
      {4, {:dip, 0.935}, nil, "Discharge check"},
      {14, {:z, 0.15}, {:z, 0.15}, nil},
      {32, {:z, 0.4}, {:z, 0.3}, nil},
      {46, {:z, 0.5}, nil, "Home scale"},
      {60, {:z, 0.6}, {:z, 0.4}, "Two-month visit"}
    ]

    {rows, _birth_g} =
      Enum.flat_map_reduce(plan, nil, fn {offset, w_spec, h_spec, note}, birth_g ->
        date = Date.add(birth_date, offset)
        at = child |> Child.day_bounds(date) |> elem(0) |> DateTime.truncate(:second)

        if DateTime.compare(at, now) == :gt do
          {[], birth_g}
        else
          weight = weight_for(child, w_spec, date, birth_g)
          height = if h_spec, do: height_for(child, h_spec, date), else: nil
          {[growth_row(child, user, at, weight, height, note)], birth_g || weight}
        end
      end)

    rows
  end

  defp weight_for(_child, {:dip, factor}, _date, birth_g) when is_number(birth_g) do
    round_step(birth_g * factor, 10) * 1.0
  end

  defp weight_for(child, {:dip, factor}, date, _birth_g) do
    base = Percentiles.value_at_z(child, :weight, 0.1, date) || fallback_weight(child, date)
    round_step(base * factor, 10) * 1.0
  end

  defp weight_for(child, {:z, z}, date, _birth_g) do
    base = Percentiles.value_at_z(child, :weight, z, date) || fallback_weight(child, date)
    jitter = (:rand.uniform() - 0.5) * 0.024
    round_step(base * (1 + jitter), 10) * 1.0
  end

  defp height_for(child, {:z, z}, date) do
    base = Percentiles.value_at_z(child, :length, z, date) || fallback_height(child, date)
    Float.round(base + (:rand.uniform() - 0.5) * 0.8, 1)
  end

  defp fallback_weight(child, date), do: 3300.0 + Date.diff(date, child.birth_date) * 28.0
  defp fallback_height(child, date), do: 50.0 + Date.diff(date, child.birth_date) * 0.12

  defp growth_row(child, user, at, weight_g, height_cm, note) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      child_id: child.id,
      logged_by_id: user.id,
      measured_at: at,
      weight_g: weight_g,
      height_cm: height_cm,
      note: note,
      inserted_at: now,
      updated_at: now
    }
  end

  # --- newborn shape -------------------------------------------------------

  defp feed_amount(age) do
    base = 15 + age * 9.0
    jitter = (:rand.uniform() - 0.5) * 18
    # Colostrum-era sips climb fast, then level off around a full bottle.
    ceiling = min(95.0 + max(age - 7.0, 0.0) * 1.6, 165.0)
    (base + jitter) |> max(15.0) |> min(ceiling) |> round_step(5)
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
end

Trygg.DevSeeds.run()
