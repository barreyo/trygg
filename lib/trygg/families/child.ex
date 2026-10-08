defmodule Trygg.Families.Child do
  use Ecto.Schema
  import Ecto.Changeset

  @sexes [:female, :male, :unspecified]
  # What the Home screen can track — the same atoms as `Trygg.Log.Entry` types.
  # A child tracks all of them unless a caregiver trims the list down.
  @tracked_types [:feeding, :diaper, :sleep]
  # New children default to the San Francisco Bay Area; the IANA zone handles
  # PST/PDT automatically.
  @default_timezone "America/Los_Angeles"

  # A full-term pregnancy is 40+0 weeks. Babies born before 39+0 — preterm
  # (before 37+0) or early term (37+0 to 38+6) — get corrected age.
  @term_days 280
  @full_term_days 273
  # Chronological age at which corrected age stops being used.
  @correct_until_days 730
  @gestation_weeks 22..42

  schema "children" do
    field :name, :string
    field :birth_date, :date
    field :birth_time, :time
    # Set while the child is still "expecting" — the due date. Cleared when a
    # caregiver confirms the real `birth_date`. See `expecting?/1`.
    field :expected_birth_date, :date
    # Gestational age at birth in days (34+2 weeks = 240); `nil` when unknown
    # or full term. Edited through the virtual weeks/days pair below.
    field :gestational_age_days, :integer
    field :gestation_weeks, :integer, virtual: true
    field :gestation_extra_days, :integer, virtual: true
    field :sex, Ecto.Enum, values: @sexes, default: :unspecified
    field :timezone, :string, default: @default_timezone
    field :day_start, :time, default: ~T[08:00:00]
    field :night_start, :time, default: ~T[20:00:00]

    # Daily vitamin D drop tracking. When on, caregivers get a push if no drop
    # has been logged by `Trygg.Log.VitaminDReminders.deadline/0` in the
    # child's time zone. `vitamin_d_reminded_on` is bookkeeping set by the
    # reminder scan (never cast) so it fires at most once per local day.
    field :vitamin_d_reminder, :boolean, default: false
    field :vitamin_d_reminded_on, :date

    # Which trackers show on Home (glance cards, log buttons, recent list).
    # Shared by every caregiver; at least one must stay on.
    field :tracked_types, {:array, Ecto.Enum}, values: @tracked_types, default: @tracked_types

    # Populated by `Trygg.Families` with the current user's role for this child.
    field :role, Ecto.Enum, values: [:owner, :caregiver, :viewer], virtual: true

    belongs_to :family, Trygg.Families.Family

    has_many :memberships, through: [:family, :memberships]
    has_many :caregivers, through: [:memberships, :user]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(child, attrs) do
    child
    |> with_gestation_fields()
    |> cast(attrs, [
      :name,
      :birth_date,
      :birth_time,
      :expected_birth_date,
      :sex,
      :timezone,
      :day_start,
      :night_start,
      :vitamin_d_reminder,
      :tracked_types,
      :gestation_weeks,
      :gestation_extra_days
    ])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :timezone, :day_start, :night_start])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_tracked_types()
    |> validate_timezone()
    |> validate_birth_date()
    |> validate_expected_birth_date()
    |> put_gestational_age()
    |> truncate_time(:day_start)
    |> truncate_time(:night_start)
    |> validate_day_night()
  end

  # Seed the virtual weeks/days pair from the stored total so the form shows
  # it and an untouched form doesn't register a change.
  defp with_gestation_fields(%__MODULE__{gestational_age_days: days} = child)
       when is_integer(days),
       do: %{child | gestation_weeks: div(days, 7), gestation_extra_days: rem(days, 7)}

  defp with_gestation_fields(child), do: child

  defp put_gestational_age(changeset) do
    if changed?(changeset, :gestation_weeks) or changed?(changeset, :gestation_extra_days) do
      changeset =
        changeset
        |> validate_inclusion(:gestation_weeks, @gestation_weeks,
          message: "must be between #{@gestation_weeks.first} and #{@gestation_weeks.last} weeks"
        )
        |> validate_inclusion(:gestation_extra_days, 0..6, message: "must be 0–6 days")

      case get_field(changeset, :gestation_weeks) do
        nil ->
          put_change(changeset, :gestational_age_days, nil)

        weeks ->
          extra = get_field(changeset, :gestation_extra_days) || 0
          put_change(changeset, :gestational_age_days, weeks * 7 + extra)
      end
    else
      changeset
    end
  end

  defp validate_tracked_types(changeset) do
    changeset = update_change(changeset, :tracked_types, &Enum.uniq/1)

    if get_field(changeset, :tracked_types) == [] do
      add_error(changeset, :tracked_types, "pick at least one thing to track")
    else
      changeset
    end
  end

  defp truncate_time(changeset, field) do
    case get_change(changeset, field) do
      %Time{} = time -> put_change(changeset, field, Time.truncate(time, :second))
      _ -> changeset
    end
  end

  defp validate_timezone(changeset) do
    case get_field(changeset, :timezone) do
      nil ->
        changeset

      tz ->
        if match?({:ok, _}, DateTime.now(tz)) do
          changeset
        else
          add_error(changeset, :timezone, "isn't a known time zone")
        end
    end
  end

  defp validate_day_night(changeset) do
    day = get_field(changeset, :day_start)
    night = get_field(changeset, :night_start)

    cond do
      is_nil(day) or is_nil(night) ->
        changeset

      Time.compare(Time.truncate(day, :second), Time.truncate(night, :second)) == :eq ->
        add_error(changeset, :night_start, "must be different from when day starts")

      true ->
        changeset
    end
  end

  defp validate_birth_date(changeset) do
    case get_field(changeset, :birth_date) do
      nil ->
        changeset

      %Date{} = date ->
        if Date.after?(date, Date.utc_today()) do
          add_error(changeset, :birth_date, "can't be in the future")
        else
          changeset
        end
    end
  end

  # The expected delivery date must be today or later — but only checked when it
  # actually changes, so a child whose due date has quietly slipped into the
  # past can still be edited (rename, timezone, …) while everyone waits.
  defp validate_expected_birth_date(changeset) do
    case get_change(changeset, :expected_birth_date) do
      %Date{} = date ->
        if Date.before?(date, Date.utc_today()) do
          add_error(
            changeset,
            :expected_birth_date,
            "has already passed — if the baby's here, mark them as born"
          )
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  @doc "The child's wall-clock `DateTime` right now, in its own time zone."
  def local_now(%__MODULE__{timezone: tz}), do: DateTime.now!(tz)

  @doc "The child's current local calendar date."
  def local_today(%__MODULE__{} = child), do: DateTime.to_date(local_now(child))

  @doc """
  The child's age as a `{years, months, days}` tuple, measured against `today`
  (defaults to the child's own local calendar date). Returns `nil` when there's
  no birth date, or when the birth date is after `today`.
  """
  def age(child, today \\ nil)

  def age(%__MODULE__{birth_date: nil}, _today), do: nil

  def age(%__MODULE__{birth_date: %Date{} = dob} = child, today) do
    today = today || local_today(child)
    if Date.after?(dob, today), do: nil, else: ymd_between(dob, today)
  end

  @doc ~S'A compact "1y 2mo 5d" label for `age/1`, or `nil` when age is unknown.'
  def age_label(%__MODULE__{} = child) do
    case age(child) do
      {y, m, d} -> "#{y}y #{m}mo #{d}d"
      nil -> nil
    end
  end

  @doc """
  Whether the child hasn't been born yet: an `expected_birth_date` is set and
  no `birth_date` has been confirmed. While this is true the app runs in
  "practice" mode and everything logged is cleared once the baby arrives.
  """
  def expecting?(%__MODULE__{birth_date: nil, expected_birth_date: %Date{}}), do: true
  def expecting?(%__MODULE__{}), do: false

  @doc ~S'A friendly "due in 3 weeks" / "due today" / "due 2 days ago" label, or `nil`.'
  def due_label(%__MODULE__{expected_birth_date: %Date{} = due} = child) do
    days = Date.diff(due, local_today(child))

    cond do
      days == 0 -> "due today"
      days == 1 -> "due tomorrow"
      days == -1 -> "due yesterday"
      days < 0 -> "due #{overdue_phrase(-days)} ago"
      days < 14 -> "due in #{days} days"
      days < 60 -> "due in #{div(days + 3, 7)} weeks"
      true -> "due in #{div(days, 30)} months"
    end
  end

  def due_label(%__MODULE__{}), do: nil

  defp overdue_phrase(days) when days < 14, do: "#{days} days"
  defp overdue_phrase(days) when days < 60, do: "#{div(days + 3, 7)} weeks"
  defp overdue_phrase(days), do: "#{div(days, 30)} months"

  @doc """
  Gestational age at birth implied by a due date, in days, or `nil` when it
  falls outside the range the form accepts (a due date that was never updated,
  say).
  """
  def gestational_age_from_due_date(%Date{} = birth_date, %Date{} = due) do
    days = @term_days - Date.diff(due, birth_date)
    if div(days, 7) in @gestation_weeks, do: days
  end

  def gestational_age_from_due_date(_birth_date, _due), do: nil

  @doc """
  Whether the child was born before 39+0 weeks — preterm or early term — and
  so gets corrected age.
  """
  def born_early?(%__MODULE__{gestational_age_days: days}) when is_integer(days),
    do: days < @full_term_days

  def born_early?(%__MODULE__{}), do: false

  @doc """
  The date a child born early reached 40+0 weeks — where corrected age starts
  counting from. `nil` for term children or without a birth date.
  """
  def term_date(%__MODULE__{birth_date: %Date{} = dob, gestational_age_days: days} = child) do
    if born_early?(child), do: Date.add(dob, @term_days - days)
  end

  def term_date(%__MODULE__{}), do: nil

  @doc """
  The child with gestational age ignored, so percentiles and norms use actual
  (chronological) age — for comparing with a chart that isn't corrected.
  Display only; never persist the result.
  """
  def uncorrected(%__MODULE__{} = child), do: %{child | gestational_age_days: nil}

  @doc """
  Whether age-based comparisons on `date` should use corrected age: the child
  was born before 39+0 weeks and is younger than two. Two is the usual
  clinical cut-off; correcting early-term (37–38 week) babies is a deliberate
  choice beyond the usual preterm-only convention.
  """
  def corrects_age?(%__MODULE__{birth_date: %Date{} = dob} = child, %Date{} = date) do
    born_early?(child) and Date.diff(date, dob) < @correct_until_days
  end

  def corrects_age?(%__MODULE__{}, _date), do: false

  @doc """
  Postmenstrual age on `date` in days — gestational age at birth plus days
  since birth — or `nil` without a gestational age or birth date, or before
  birth.
  """
  def postmenstrual_age_days(
        %__MODULE__{birth_date: %Date{} = dob, gestational_age_days: ga},
        %Date{} = date
      )
      when is_integer(ga) do
    days = Date.diff(date, dob)
    if days >= 0, do: ga + days
  end

  def postmenstrual_age_days(%__MODULE__{}, _date), do: nil

  @doc ~S'Postmenstrual age on `date` as `"38+2 weeks"`, or `nil`.'
  def postmenstrual_age_label(%__MODULE__{} = child, %Date{} = date) do
    with days when is_integer(days) <- postmenstrual_age_days(child, date),
         do: "#{div(days, 7)}+#{rem(days, 7)} weeks"
  end

  @doc ~S'Gestational age at birth as `"34+2 weeks"`, or `nil` when unknown.'
  def gestation_label(%__MODULE__{gestational_age_days: days}) when is_integer(days),
    do: "#{div(days, 7)}+#{rem(days, 7)} weeks"

  def gestation_label(%__MODULE__{}), do: nil

  @doc """
  Age counted from `term_date/1` as `{years, months, days}`, or `nil` for term
  children and before the term date.
  """
  def corrected_age(%__MODULE__{} = child, today \\ nil) do
    with %Date{} = term <- term_date(child) do
      today = today || local_today(child)
      if Date.after?(term, today), do: nil, else: ymd_between(term, today)
    end
  end

  @doc "The best one-line caption for the child: their age, or their due date."
  def caption(%__MODULE__{} = child) do
    if expecting?(child), do: due_label(child), else: age_label(child)
  end

  # Whole years/months/days between two dates, borrowing from the larger unit
  # when a component goes negative (calendar-aware, so month length matters).
  defp ymd_between(dob, today) do
    years = today.year - dob.year
    months = today.month - dob.month
    days = today.day - dob.day

    {days, months} =
      if days < 0 do
        prev_month = Date.add(%{today | day: 1}, -1)
        {days + prev_month.day, months - 1}
      else
        {days, months}
      end

    {months, years} = if months < 0, do: {months + 12, years - 1}, else: {months, years}

    {years, months, days}
  end

  @doc """
  The `{start_utc, end_utc}` UTC datetimes bounding the child's local calendar
  `date` (defaults to today). DST-aware: the day may be 23 or 25 hours long.
  """
  def day_bounds(%__MODULE__{timezone: tz} = child, date \\ nil) do
    date = date || local_today(child)
    {local_midnight(date, tz), local_midnight(Date.add(date, 1), tz)}
  end

  @doc """
  UTC datetime of `time` on the child's local `date`. DST-aware: spring-forward
  gaps snap to the moment after, fall-back duplicates pick the earlier instant.
  """
  def at_local(%__MODULE__{timezone: tz}, %Date{} = date, %Time{} = time) do
    naive = NaiveDateTime.new!(date, Time.truncate(time, :second))
    {:ok, dt} = naive_in_zone(naive, tz)
    dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
  end

  @doc "UTC datetime of the child's day-start clock on local `date`."
  def day_start_at(%__MODULE__{} = child, date), do: at_local(child, date, child.day_start)

  @doc "UTC datetime of the child's night-start clock on local `date`."
  def night_start_at(%__MODULE__{} = child, date), do: at_local(child, date, child.night_start)

  @doc """
  The overnight window that *starts* on local `date`: `{night_start on date,
  day_start on date + 1}`, both UTC.
  """
  def night_bounds(%__MODULE__{} = child, date \\ nil) do
    date = date || local_today(child)
    {night_start_at(child, date), day_start_at(child, Date.add(date, 1))}
  end

  @doc "Whether `dt` falls in the child's daytime (`day_start` until `night_start`)."
  def daytime?(%__MODULE__{} = child, %DateTime{} = dt) do
    local = DateTime.shift_zone!(dt, child.timezone)
    t = local |> DateTime.to_time() |> Time.truncate(:second)
    day = Time.truncate(child.day_start, :second)
    night = Time.truncate(child.night_start, :second)

    case Time.compare(day, night) do
      :lt -> Time.compare(t, day) != :lt and Time.compare(t, night) == :lt
      :gt -> Time.compare(t, day) != :lt or Time.compare(t, night) == :lt
      :eq -> false
    end
  end

  @doc ~S'Formats a `Time` as `"HH:MM"`.'
  def format_clock(%Time{} = time), do: Calendar.strftime(Time.truncate(time, :second), "%H:%M")

  @doc "`HH:MM` for a UTC datetime, in the child's local time."
  def local_clock(%__MODULE__{timezone: tz}, %DateTime{} = dt) do
    dt |> DateTime.shift_zone!(tz) |> Calendar.strftime("%H:%M")
  end

  @doc """
  Formats a UTC datetime as `YYYY-MM-DDTHH:MM` in the child's local time, for
  seeding a `<input type="datetime-local">`.
  """
  def to_local_input(%__MODULE__{timezone: tz}, %DateTime{} = dt) do
    dt |> DateTime.shift_zone!(tz) |> Calendar.strftime("%Y-%m-%dT%H:%M")
  end

  @doc """
  Parses a local-time `YYYY-MM-DDTHH:MM` string (from a datetime-local input)
  into a UTC `DateTime`. Returns `{:ok, datetime}` or `:error`.
  """
  def from_local_input(%__MODULE__{timezone: tz}, value) when is_binary(value) do
    trimmed = String.trim(value)
    iso = if String.length(trimmed) == 16, do: trimmed <> ":00", else: trimmed

    with {:ok, naive} <- NaiveDateTime.from_iso8601(iso),
         {:ok, dt} <- naive_in_zone(naive, tz) do
      {:ok, dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)}
    else
      _ -> :error
    end
  end

  def from_local_input(_child, _value), do: :error

  # A local wall-clock time can be ambiguous (fall-back) or nonexistent
  # (spring-forward). Pick the earlier instant / the moment after the gap.
  defp naive_in_zone(naive, tz) do
    case DateTime.from_naive(naive, tz) do
      {:ok, dt} -> {:ok, dt}
      {:ambiguous, first, _second} -> {:ok, first}
      {:gap, _before, after_gap} -> {:ok, after_gap}
      other -> other
    end
  end

  defp local_midnight(date, tz) do
    {:ok, dt} = naive_in_zone(NaiveDateTime.new!(date, ~T[00:00:00]), tz)
    DateTime.shift_zone!(dt, "Etc/UTC")
  end

  @doc "Whether the Home screen tracks entries of `type` (`:feeding`, `:diaper`, `:sleep`) for the child."
  def tracks?(%__MODULE__{tracked_types: types}, type), do: type in types

  def tracked_types, do: @tracked_types
  def sexes, do: @sexes
  def gestation_weeks, do: @gestation_weeks
  def default_timezone, do: @default_timezone
  def default_day_start, do: ~T[08:00:00]
  def default_night_start, do: ~T[20:00:00]
end
