defmodule Trygg.Families.ChildTest do
  use ExUnit.Case, async: true

  alias Trygg.Families.Child

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
end
