defmodule Trygg.Growth.PercentilesTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child
  alias Trygg.Growth.Percentiles

  # CDC wtageinf.csv, sex 1 (male), Agemos 0.
  @male_birth_p50_kg 3.530203168
  @male_birth_p5_kg 2.52690402
  @male_birth_p95_kg 4.34029274

  # CDC lenageinf.csv, sex 2 (female), Agemos 0.
  @female_birth_length_p50_cm 49.28639612

  defp child(attrs) do
    struct(
      %Child{
        name: "Test",
        birth_date: ~D[2026-08-01],
        sex: :female,
        timezone: "Etc/UTC"
      },
      attrs
    )
  end

  describe "percentile/4" do
    test "male birth weight at the CDC median is the 50th" do
      boy = child(sex: :male, birth_date: ~D[2026-08-01])

      assert Percentiles.percentile(boy, :weight, @male_birth_p50_kg * 1000, ~D[2026-08-01]) ==
               50
    end

    test "male birth weight at the published 5th is the 5th" do
      boy = child(sex: :male, birth_date: ~D[2026-08-01])

      assert Percentiles.percentile(boy, :weight, @male_birth_p5_kg * 1000, ~D[2026-08-01]) == 5
    end

    test "female birth length at the CDC median is the 50th" do
      girl = child(sex: :female, birth_date: ~D[2026-08-01])

      assert Percentiles.percentile(
               girl,
               :length,
               @female_birth_length_p50_cm,
               ~D[2026-08-01]
             ) == 50
    end

    test "returns nil without a birth date, sex, or when older than 36 months" do
      assert Percentiles.percentile(child(birth_date: nil), :weight, 3500, ~D[2026-08-01]) == nil

      assert Percentiles.percentile(child(sex: :unspecified), :weight, 3500, ~D[2026-08-01]) ==
               nil

      old = child(birth_date: ~D[2022-01-01])
      assert Percentiles.percentile(old, :weight, 14_000, ~D[2026-08-01]) == nil
    end
  end

  describe "value_at/4" do
    test "reconstructs the published male birth 5th/50th/95th weights" do
      boy = child(sex: :male, birth_date: ~D[2026-08-01])
      date = ~D[2026-08-01]

      assert_in_delta Percentiles.value_at(boy, :weight, 50, date) / 1000,
                      @male_birth_p50_kg,
                      0.001

      assert_in_delta Percentiles.value_at(boy, :weight, 5, date) / 1000, @male_birth_p5_kg, 0.001

      assert_in_delta Percentiles.value_at(boy, :weight, 95, date) / 1000,
                      @male_birth_p95_kg,
                      0.001
    end

    test "interpolates between tabulated ages" do
      boy = child(sex: :male, birth_date: ~D[2026-01-01])
      # 1.0 month sits between Agemos 0.5 and 1.5.
      at_one_month = Percentiles.value_at(boy, :weight, 50, ~D[2026-02-01])
      at_half = Percentiles.value_at(boy, :weight, 50, ~D[2026-01-16])
      at_one_and_half = Percentiles.value_at(boy, :weight, 50, ~D[2026-02-16])

      assert at_half < at_one_month
      assert at_one_month < at_one_and_half
    end
  end

  describe "curve/5" do
    test "is empty for unspecified sex and samples the window otherwise" do
      assert Percentiles.curve(
               child(sex: :unspecified),
               :weight,
               50,
               ~D[2026-08-01],
               ~D[2026-08-20]
             ) ==
               []

      girl = child(sex: :female, birth_date: ~D[2026-08-01])
      points = Percentiles.curve(girl, :weight, 50, ~D[2026-08-01], ~D[2026-08-20])

      assert length(points) >= 2
      assert {~D[2026-08-01], birth} = hd(points)
      assert {~D[2026-08-20], later} = List.last(points)
      assert later > birth
    end
  end

  describe "format_percentile/1" do
    test "ordinals and tails" do
      assert Percentiles.format_percentile(1) == "1st"
      assert Percentiles.format_percentile(2) == "2nd"
      assert Percentiles.format_percentile(3) == "3rd"
      assert Percentiles.format_percentile(4) == "4th"
      assert Percentiles.format_percentile(11) == "11th"
      assert Percentiles.format_percentile(12) == "12th"
      assert Percentiles.format_percentile(21) == "21st"
      assert Percentiles.format_percentile(42) == "42nd"
      assert Percentiles.format_percentile({:below, 1}) == "<1st"
      assert Percentiles.format_percentile({:above, 99}) == ">99th"
      assert Percentiles.format_percentile(nil) == nil
    end
  end

  describe "hint/1 and source_label/1" do
    test "explains missing sex or birth date" do
      assert Percentiles.hint(child(sex: :unspecified)) == :unspecified_sex
      assert Percentiles.hint(child(birth_date: nil)) == :no_birth_date
      assert Percentiles.hint(child(sex: :female)) == nil
      assert Percentiles.source_label(child(sex: :female)) =~ "girls"
      assert Percentiles.source_label(child(sex: :male)) =~ "boys"
      assert Percentiles.source_label(child(sex: :unspecified)) == nil
    end
  end

  describe "corrected age for preterm babies" do
    # Born at 32+0 weeks: term (40+0) is 56 days after birth.
    defp preterm(attrs \\ []) do
      child(
        Keyword.merge([sex: :male, birth_date: ~D[2026-01-01], gestational_age_days: 224], attrs)
      )
    end

    test "scores against a term baby born on the term date" do
      baby = preterm()
      twin = child(sex: :male, birth_date: ~D[2026-02-26])

      for date <- [~D[2026-02-26], ~D[2026-05-10], ~D[2027-06-01]] do
        assert Percentiles.zscore(baby, :weight, 5000, date) ==
                 Percentiles.zscore(twin, :weight, 5000, date)

        assert Percentiles.percentile(baby, :length, 60, date) ==
                 Percentiles.percentile(twin, :length, 60, date)
      end
    end

    test "has no percentile before the term date" do
      assert Percentiles.percentile(preterm(), :weight, 2000, ~D[2026-02-25]) == nil
      assert Percentiles.value_at(preterm(), :weight, 50, ~D[2026-02-01]) == nil
      assert Percentiles.hint(preterm(), ~D[2026-02-25]) == :before_term
      assert Percentiles.hint(preterm(), ~D[2026-02-26]) == nil
    end

    test "switches back to chronological age at two" do
      baby = preterm()
      term = child(sex: :male, birth_date: ~D[2026-01-01])

      assert Percentiles.corrected?(baby, ~D[2027-12-31])
      refute Percentiles.corrected?(baby, ~D[2028-01-02])

      assert Percentiles.zscore(baby, :weight, 12_000, ~D[2028-02-01]) ==
               Percentiles.zscore(term, :weight, 12_000, ~D[2028-02-01])
    end

    test "the :corrected option pins the age basis" do
      baby = preterm()
      date = ~D[2028-02-01]

      assert Percentiles.zscore(baby, :weight, 12_000, date, corrected: true) >
               Percentiles.zscore(baby, :weight, 12_000, date)

      # A term baby has nothing to correct.
      term = child(sex: :male, birth_date: ~D[2026-01-01])

      assert Percentiles.zscore(term, :weight, 12_000, date, corrected: true) ==
               Percentiles.zscore(term, :weight, 12_000, date)
    end

    test "early-term babies are corrected; 39 weeks and later aren't" do
      assert Percentiles.corrected?(preterm(gestational_age_days: 264), ~D[2026-03-01])
      assert Percentiles.corrected?(preterm(gestational_age_days: 272), ~D[2026-03-01])
      refute Percentiles.corrected?(preterm(gestational_age_days: 273), ~D[2026-03-01])
    end

    test "a 37+5 baby scores like a term baby born 16 days later" do
      baby = preterm(gestational_age_days: 264)
      twin = child(sex: :male, birth_date: ~D[2026-01-17])

      assert Percentiles.percentile(baby, :weight, 4000, ~D[2026-01-31]) ==
               Percentiles.percentile(twin, :weight, 4000, ~D[2026-01-31])

      assert Percentiles.source_label(baby, ~D[2026-01-31]) =~ "born at 37+5 weeks"
    end

    test "curves start at the term date" do
      [{first, _} | _] =
        Percentiles.curve(preterm(), :weight, 50, ~D[2026-01-01], ~D[2026-06-01])

      assert first == ~D[2026-02-26]
    end

    test "the source label mentions the correction while it applies" do
      assert Percentiles.source_label(preterm(), ~D[2026-06-01]) =~
               "corrected age (born at 32+0 weeks)"

      refute Percentiles.source_label(preterm(), ~D[2028-06-01]) =~ "corrected"
    end
  end
end
