defmodule Trygg.Families.ChildTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child

  defp base_attrs(extra) do
    Map.merge(
      %{name: "Bump", timezone: "Etc/UTC", day_start: ~T[08:00:00], night_start: ~T[20:00:00]},
      extra
    )
  end

  defp errors_on_cs(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, _opts} -> msg end)
  end

  describe "age/2" do
    test "nil when there is no birth date" do
      assert Child.age(%Child{birth_date: nil}, ~D[2026-09-01]) == nil
    end

    test "nil when the birth date is after the reference day" do
      assert Child.age(%Child{birth_date: ~D[2026-09-02]}, ~D[2026-09-01]) == nil
    end

    test "zero on the day of birth" do
      assert Child.age(%Child{birth_date: ~D[2026-09-01]}, ~D[2026-09-01]) == {0, 0, 0}
    end

    test "counts whole years, months and days" do
      assert Child.age(%Child{birth_date: ~D[2024-06-10]}, ~D[2026-09-25]) == {2, 3, 15}
    end

    test "borrows a calendar month when the day component is negative" do
      assert Child.age(%Child{birth_date: ~D[2025-01-20]}, ~D[2026-09-01]) == {1, 7, 12}
    end

    test "borrows across the year boundary" do
      assert Child.age(%Child{birth_date: ~D[2025-11-15]}, ~D[2026-02-10]) == {0, 2, 26}
    end

    test "uses the previous month's real length when borrowing" do
      # March 1 minus a Feb-anchored birthday: 2024 is a leap year (29 days).
      assert Child.age(%Child{birth_date: ~D[2020-02-15]}, ~D[2024-03-01]) == {4, 0, 15}
    end
  end

  describe "age_label/1" do
    test "renders the compact y/mo/d string" do
      assert Child.age_label(%Child{birth_date: nil}) == nil

      # default reference date is the child's local today
      child = %Child{birth_date: Date.utc_today(), timezone: "Etc/UTC"}
      assert Child.age_label(child) == "0y 0mo 0d"
    end
  end

  describe "expecting?/1" do
    test "true only with a due date and no birth date" do
      due = Date.add(Date.utc_today(), 30)
      assert Child.expecting?(%Child{birth_date: nil, expected_birth_date: due})
      refute Child.expecting?(%Child{birth_date: nil, expected_birth_date: nil})

      refute Child.expecting?(%Child{
               birth_date: Date.utc_today(),
               expected_birth_date: due
             })
    end
  end

  describe "due_label/1 and caption/1" do
    test "friendly relative phrasing around the due date" do
      today = Date.utc_today()

      label = fn days ->
        Child.due_label(%Child{
          timezone: "Etc/UTC",
          expected_birth_date: Date.add(today, days)
        })
      end

      assert label.(0) == "due today"
      assert label.(1) == "due tomorrow"
      assert label.(5) == "due in 5 days"
      assert label.(21) == "due in 3 weeks"
      assert label.(-1) == "due yesterday"
      assert label.(-5) == "due 5 days ago"
    end

    test "caption/1 falls back to the age once born" do
      expecting = %Child{timezone: "Etc/UTC", expected_birth_date: Date.add(Date.utc_today(), 10)}
      assert Child.caption(expecting) =~ "due in"

      born = %Child{timezone: "Etc/UTC", birth_date: Date.utc_today()}
      assert Child.caption(born) == "0y 0mo 0d"
    end
  end

  describe "changeset/2 expected_birth_date" do
    test "accepts a future due date" do
      cs =
        Child.changeset(
          %Child{},
          base_attrs(%{expected_birth_date: Date.add(Date.utc_today(), 40)})
        )

      assert cs.valid?
    end

    test "rejects a due date that has already passed when it changes" do
      cs =
        Child.changeset(
          %Child{},
          base_attrs(%{expected_birth_date: Date.add(Date.utc_today(), -1)})
        )

      refute cs.valid?
      assert %{expected_birth_date: [_ | _]} = errors_on_cs(cs)
    end

    test "still rejects a future birth_date" do
      cs =
        Child.changeset(%Child{}, base_attrs(%{birth_date: Date.add(Date.utc_today(), 3)}))

      refute cs.valid?
      assert %{birth_date: ["can't be in the future"]} = errors_on_cs(cs)
    end
  end

  describe "gestational age" do
    test "weeks and days combine into gestational_age_days" do
      cs =
        Child.changeset(%Child{}, base_attrs(%{gestation_weeks: "34", gestation_extra_days: "2"}))

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :gestational_age_days) == 240
    end

    test "clearing the weeks clears the stored value" do
      cs = Child.changeset(%Child{gestational_age_days: 240}, base_attrs(%{gestation_weeks: ""}))
      assert Ecto.Changeset.get_change(cs, :gestational_age_days, :unchanged) == nil
    end

    test "an untouched form keeps the stored value without a change" do
      child = %Child{gestational_age_days: 240}
      cs = Child.changeset(child, base_attrs(%{gestation_weeks: "34", gestation_extra_days: "2"}))

      assert Ecto.Changeset.get_field(cs, :gestation_weeks) == 34
      refute Map.has_key?(cs.changes, :gestational_age_days)
    end

    test "rejects weeks outside the chart range" do
      cs = Child.changeset(%Child{}, base_attrs(%{gestation_weeks: "18"}))
      refute cs.valid?
      assert %{gestation_weeks: [_ | _]} = errors_on_cs(cs)
    end

    test "born_early?, term_date and corrected_age" do
      baby = %Child{timezone: "Etc/UTC", birth_date: ~D[2026-01-01], gestational_age_days: 224}

      assert Child.born_early?(baby)
      assert Child.gestation_label(baby) == "32+0 weeks"
      assert Child.term_date(baby) == ~D[2026-02-26]
      assert Child.corrected_age(baby, ~D[2026-02-25]) == nil
      assert Child.corrected_age(baby, ~D[2026-04-01]) == {0, 1, 6}

      # Early term (37+5) is corrected too; 39+0 and later isn't.
      early_term = %{baby | gestational_age_days: 264}
      assert Child.born_early?(early_term)
      assert Child.term_date(early_term) == ~D[2026-01-17]

      term = %{baby | gestational_age_days: 273}
      refute Child.born_early?(term)
      assert Child.term_date(term) == nil
      refute Child.born_early?(%{baby | gestational_age_days: nil})
    end

    test "gestational_age_from_due_date/2" do
      assert Child.gestational_age_from_due_date(~D[2026-01-01], ~D[2026-02-26]) == 224
      assert Child.gestational_age_from_due_date(~D[2026-01-10], ~D[2026-01-03]) == 287
      # A due date that can't be right (a year out) gives nothing.
      assert Child.gestational_age_from_due_date(~D[2026-01-01], ~D[2027-01-01]) == nil
    end
  end
end
