defmodule Trygg.Growth.CheckReminderTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Growth.CheckReminder
  alias Trygg.Growth.Measurement

  @today ~D[2026-06-01]

  defp child(birth_days_ago) do
    %Child{
      timezone: "Etc/UTC",
      birth_date: birth_days_ago && Date.add(@today, -birth_days_ago)
    }
  end

  defp weight(days_ago) do
    at = DateTime.new!(Date.add(@today, -days_ago), ~T[00:00:00], "Etc/UTC")
    %Measurement{measured_at: at, weight_g: 5000.0}
  end

  test "due when the last weight is older than the age-based interval" do
    # ~7 months old -> a 90-day check interval
    status = CheckReminder.evaluate(child(200), weight(120), @today)

    assert status.due?
    assert status.interval_days == 90
    assert status.days_since == 120
    assert status.overdue_days == 30
    refute status.never_measured?
    assert status.last_measured_on == Date.add(@today, -120)
  end

  test "interval widens with age" do
    assert CheckReminder.evaluate(child(15), weight(30), @today).interval_days == 21
    assert CheckReminder.evaluate(child(60), weight(10), @today).interval_days == 42
    assert CheckReminder.evaluate(child(200), weight(10), @today).interval_days == 90
    assert CheckReminder.evaluate(child(500), weight(10), @today).interval_days == 120
    assert CheckReminder.evaluate(child(1000), weight(10), @today).interval_days == 182
    assert CheckReminder.evaluate(child(3000), weight(10), @today).interval_days == 365
  end

  test "not due when a recent weight is on file" do
    status = CheckReminder.evaluate(child(200), weight(10), @today)

    refute status.due?
    assert status.overdue_days == 0
  end

  test "falls back to the birth date when no weight was ever logged" do
    # 25 days old -> newborn interval of 21 days, and never weighed
    status = CheckReminder.evaluate(child(25), nil, @today)

    assert status.never_measured?
    assert status.due?
    assert status.days_since == 25
    assert status.interval_days == 21
  end

  test "not due for a newborn still inside the first interval" do
    status = CheckReminder.evaluate(child(10), nil, @today)

    refute status.due?
  end

  test "nil when there is nothing to anchor on" do
    assert CheckReminder.evaluate(child(nil), nil, @today) == nil
  end

  test "unknown age uses the conservative 90-day interval" do
    status = CheckReminder.evaluate(child(nil), weight(100), @today)

    assert status.interval_days == 90
    assert status.due?
  end
end
