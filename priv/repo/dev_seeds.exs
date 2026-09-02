# Local-dev seed data.
#
#     mix seed.dev
#     # or: mix run priv/repo/dev_seeds.exs
#
# Creates (or reuses) a magic-link user `hello@johabackman.com` / "Johan Backman"
# and a one-week-old daughter, Astrid, then fills her shared log with a realistic
# week of newborn life: bottle feeds every couple of hours (small colostrum-era
# amounts growing day by day), a dozen-ish diapers a day (meconium → transitional →
# seedy yellow), and the short, scattered sleeps of a newborn — night stretches
# in the bassinet, daytime contact naps, an evening cluster-feed slump. If the
# current wall-clock lands mid-nap, that nap is left running so the dashboard's
# live sleep timer has something to show.
#
# Re-running wipes Astrid's existing entries and regenerates, so it's safe to
# run repeatedly. The RNG is seeded, so the shape of the week is stable.

defmodule Trygg.DevSeeds do
  import Ecto.Query

  alias Trygg.{Accounts, Families, Repo}
  alias Trygg.Accounts.Scope
  alias Trygg.Log.Entry

  @email "hello@johabackman.com"
  @first_name "Johan"
  @last_name "Backman"
  @child_name "Astrid"
  @tz "America/Los_Angeles"

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

    IO.puts("""

    Seeded local dev data:
      user   #{user.email}  (#{user.first_name} #{user.last_name}, magic-link, confirmed)
      child  #{child.name}  (female, born #{DateTime.shift_zone!(birth, @tz) |> Calendar.strftime("%Y-%m-%d %H:%M")} #{@tz}, 1 week old)
      log    #{inserted} entries over 7 days#{if deleted > 0, do: "  (replaced #{deleted} previous)", else: ""}
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
end

Trygg.DevSeeds.run()
