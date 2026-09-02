defmodule Trygg.GrowthTest do
  use Trygg.DataCase, async: true

  alias Trygg.Growth
  alias Trygg.Growth.Measurement
  alias Trygg.Families.Child

  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures
  import Trygg.GrowthFixtures

  setup do
    scope = user_scope_fixture()
    %{scope: scope, child: child_fixture(scope)}
  end

  describe "create_measurement/3" do
    test "stores canonical metric units and defaults to today", %{scope: scope, child: child} do
      assert {:ok, %Measurement{} = m} =
               Growth.create_measurement(scope, child, %{
                 "weight_g" => 3200,
                 "height_cm" => 50.5,
                 "note" => "clinic"
               })

      assert m.weight_g == 3200.0
      assert m.height_cm == 50.5
      assert m.note == "clinic"
      assert m.logged_by_id == scope.user.id
      assert m.child_id == child.id

      {start, _} = Child.day_bounds(child, Child.local_today(child))
      assert DateTime.compare(m.measured_at, start) == :eq
    end

    test "accepts a measured_on date in the child's time zone", %{scope: scope, child: child} do
      date = Date.add(Child.local_today(child), -3)

      assert {:ok, m} =
               Growth.create_measurement(scope, child, %{
                 "measured_on" => date,
                 "weight_g" => 3100
               })

      {start, _} = Child.day_bounds(child, date)
      assert DateTime.compare(m.measured_at, start) == :eq
    end

    test "allows weight-only or height-only", %{scope: scope, child: child} do
      assert {:ok, w} =
               Growth.create_measurement(scope, child, %{
                 "measured_on" => Date.add(Child.local_today(child), -1),
                 "weight_g" => 3000
               })

      assert w.height_cm == nil

      assert {:ok, h} =
               Growth.create_measurement(scope, child, %{
                 "height_cm" => 49.0
               })

      assert h.weight_g == nil
    end

    test "rejects a measurement with neither metric", %{scope: scope, child: child} do
      assert {:error, cs} = Growth.create_measurement(scope, child, %{})
      assert %{weight_g: _} = errors_on(cs)
    end

    test "rejects a future date", %{scope: scope, child: child} do
      assert {:error, cs} =
               Growth.create_measurement(scope, child, %{
                 "measured_on" => Date.add(Child.local_today(child), 2),
                 "weight_g" => 3200
               })

      assert %{measured_at: _} = errors_on(cs)
    end

    test "rejects a second measurement on the same day", %{scope: scope, child: child} do
      assert {:ok, _} = Growth.create_measurement(scope, child, %{"weight_g" => 3200})

      assert {:error, cs} = Growth.create_measurement(scope, child, %{"height_cm" => 50})
      assert %{child_id: _} = errors_on(cs)
    end
  end

  describe "list and latest" do
    test "lists newest first and latest_* ignore missing metrics", %{
      scope: scope,
      child: child
    } do
      today = Child.local_today(child)

      older =
        measurement_fixture(scope, child, %{
          "measured_on" => Date.add(today, -5),
          "weight_g" => 3000,
          "height_cm" => 48
        })

      _height_only =
        measurement_fixture(scope, child, %{
          "measured_on" => Date.add(today, -1),
          "weight_g" => nil,
          "height_cm" => 50
        })

      newest_weight =
        measurement_fixture(scope, child, %{
          "measured_on" => today,
          "weight_g" => 3300,
          "height_cm" => nil
        })

      [first | _] = Growth.list_measurements(scope, child)
      assert first.id == newest_weight.id

      assert Growth.latest_weight(scope, child).id == newest_weight.id
      assert Growth.latest_height(scope, child).height_cm == 50.0
      refute Growth.latest_height(scope, child).id == older.id
    end
  end

  describe "update and delete" do
    test "update without a date keeps the original day", %{scope: scope, child: child} do
      m = measurement_fixture(scope, child)
      measured_at = m.measured_at

      assert {:ok, updated} = Growth.update_measurement(scope, m, %{"weight_g" => 3500})
      assert updated.weight_g == 3500.0
      assert DateTime.compare(updated.measured_at, measured_at) == :eq
    end

    test "update changes values and date", %{scope: scope, child: child} do
      m = measurement_fixture(scope, child)
      date = Date.add(Child.local_today(child), -2)

      assert {:ok, updated} =
               Growth.update_measurement(scope, m, %{
                 "measured_on" => date,
                 "weight_g" => 3400,
                 "height_cm" => 51
               })

      assert updated.weight_g == 3400.0
      assert updated.height_cm == 51.0
      {start, _} = Child.day_bounds(child, date)
      assert DateTime.compare(updated.measured_at, start) == :eq
    end

    test "delete removes the row", %{scope: scope, child: child} do
      m = measurement_fixture(scope, child)
      assert {:ok, _} = Growth.delete_measurement(scope, m)
      assert Growth.list_measurements(scope, child) == []
    end
  end

  describe "authorization" do
    test "viewers cannot write, can read", %{child: child} do
      viewer_user = user_fixture()
      membership_fixture(child, viewer_user, :viewer)
      viewer = user_scope_fixture(viewer_user)

      assert_raise Trygg.Families.NotAuthorizedError, fn ->
        Growth.create_measurement(viewer, child, %{"weight_g" => 3200})
      end

      assert Growth.list_measurements(viewer, child) == []
      assert Growth.latest_weight(viewer, child) == nil
    end
  end
end
