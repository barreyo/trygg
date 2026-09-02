defmodule Trygg.Families.Child do
  use Ecto.Schema
  import Ecto.Changeset

  @sexes [:female, :male, :unspecified]
  # New children default to the San Francisco Bay Area; the IANA zone handles
  # PST/PDT automatically.
  @default_timezone "America/Los_Angeles"

  schema "children" do
    field :name, :string
    field :birth_date, :date
    field :birth_time, :time
    field :sex, Ecto.Enum, values: @sexes, default: :unspecified
    field :timezone, :string, default: @default_timezone

    # Populated by `Trygg.Families` with the current user's role for this child.
    field :role, Ecto.Enum, values: [:owner, :caregiver, :viewer], virtual: true

    has_many :memberships, Trygg.Families.Membership
    has_many :caregivers, through: [:memberships, :user]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(child, attrs) do
    child
    |> cast(attrs, [:name, :birth_date, :birth_time, :sex, :timezone])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :timezone])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_timezone()
    |> validate_birth_date()
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

  def sexes, do: @sexes
  def default_timezone, do: @default_timezone
end
