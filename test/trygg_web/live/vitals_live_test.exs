defmodule TryggWeb.VitalsLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.FamiliesFixtures
  import Trygg.GrowthFixtures

  alias Trygg.Families.Child
  alias Trygg.Growth

  setup %{conn: conn} do
    %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
    %{conn: conn, scope: scope, child: child_fixture(scope)}
  end

  test "the child switcher stays on vitals for the other child", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    sibling = child_fixture(scope, %{name: "Sibling"})
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")

    {:ok, switched, _html} =
      lv
      |> element("#child-switcher-#{sibling.id}")
      |> render_click()
      |> follow_redirect(conn, ~p"/c/#{sibling}/vitals")

    assert has_element?(switched, "#child-switcher-trigger", "Sibling")
    assert has_element?(switched, "header", "Vitals")
  end

  test "empty state has latest cards, charts, and an add button", %{conn: conn, child: child} do
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")

    assert has_element?(lv, "#latest-weight", "Not logged yet")
    assert has_element?(lv, "#latest-height", "Not logged yet")
    assert has_element?(lv, "#weight-chart", "Nothing to chart yet")
    assert has_element?(lv, "#height-chart", "Nothing to chart yet")
    assert has_element?(lv, "#add-measurement")
    refute has_element?(lv, "#growth-table")
    assert has_element?(lv, "#percentile-hint")
    refute has_element?(lv, "#percentile-source")
  end

  test "logging a measurement fills latest values, the chart, and the table", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")

    lv |> element("#add-measurement") |> render_click()
    assert has_element?(lv, "#growth-form")

    today = Date.to_iso8601(Child.local_today(child))

    lv
    |> form("#growth-form",
      measurement: %{weight: "3.2", height: "50", measured_on: today, note: "clinic"}
    )
    |> render_submit()

    assert [%{weight_g: 3200.0, height_cm: 50.0, note: "clinic"}] =
             Growth.list_measurements(scope, child)

    html = render(lv)
    assert has_element?(lv, "#latest-weight", "3.2 kg")
    assert has_element?(lv, "#latest-height", "50 cm")
    assert has_element?(lv, "#growth-table")
    assert has_element?(lv, "#weight-chart svg")
    assert has_element?(lv, "#height-chart svg")
    refute html =~ "Nothing to chart yet"
  end

  test "a measurement can be edited and deleted from the table", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    m = measurement_fixture(scope, child, %{"weight_g" => 3200, "height_cm" => 50})
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")

    lv |> element("#measurement-#{m.id}") |> render_click()
    assert has_element?(lv, "#growth-form")
    assert has_element?(lv, "#delete-measurement")

    lv
    |> form("#growth-form", measurement: %{weight: "3.4", height: "51"})
    |> render_submit()

    assert Growth.get_measurement!(scope, m.id).weight_g == 3400.0
    assert has_element?(lv, "#latest-weight", "3.4 kg")

    lv |> element("#measurement-#{m.id}") |> render_click()
    lv |> element("#delete-measurement") |> render_click()

    assert Growth.list_measurements(scope, child) == []
    assert has_element?(lv, "#latest-weight", "Not logged yet")
  end

  test "a viewer can see measurements but cannot add", %{conn: conn} do
    %{owner_scope: owner_scope, child: child, member: member} = shared_child_fixture(:viewer)
    measurement_fixture(owner_scope, child)

    conn = log_in_user(conn, member)
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")

    assert has_element?(lv, "#latest-weight", "3.2 kg")
    assert has_element?(lv, "#growth-table")
    refute has_element?(lv, "#add-measurement")
    refute has_element?(lv, "#growth-form")
  end

  test "a measurement logged by another caregiver shows up live", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")
    refute has_element?(lv, "#growth-table")

    measurement_fixture(scope, child, %{"weight_g" => 3100, "height_cm" => 49})

    assert has_element?(lv, "#latest-weight", "3.1 kg")
    assert has_element?(lv, "#growth-table")
  end

  test "period chips and zoom change which points are on the chart", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    today = Child.local_today(child)

    old =
      measurement_fixture(scope, child, %{
        "measured_on" => Date.add(today, -40),
        "weight_g" => 3000,
        "height_cm" => 48
      })

    recent =
      measurement_fixture(scope, child, %{
        "measured_on" => today,
        "weight_g" => 3300,
        "height_cm" => 51
      })

    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")

    assert has_element?(lv, "#chart-range")
    assert has_element?(lv, "#chart-period-all")
    assert has_element?(lv, "#weight-chart-point-#{old.id}")
    assert has_element?(lv, "#weight-chart-point-#{recent.id}")

    lv |> element("#chart-period-weeks_2") |> render_click()

    refute has_element?(lv, "#weight-chart-point-#{old.id}")
    assert has_element?(lv, "#weight-chart-point-#{recent.id}")
    assert has_element?(lv, "#growth-table")
    assert has_element?(lv, "#measurement-#{old.id}")

    lv |> element("#chart-period-all") |> render_click()
    lv |> element("#chart-zoom-in") |> render_click()

    assert has_element?(lv, "#chart-period-year_1.btn-primary")
    assert has_element?(lv, "#weight-chart-point-#{old.id}")
  end

  test "tapping a chart point shows the reading", %{conn: conn, scope: scope, child: child} do
    m = measurement_fixture(scope, child, %{"weight_g" => 3200, "height_cm" => 50})
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")

    assert has_element?(lv, "#weight-chart-caption", "Tap a point")

    lv |> element("#weight-chart-point-#{m.id} [phx-click]") |> render_click()

    assert has_element?(lv, "#weight-chart-caption", "3.2 kg")
    assert has_element?(lv, "#weight-chart-caption", "d")
  end

  test "charts mark month and year ages along the axis", %{
    conn: conn,
    scope: scope
  } do
    today = Date.utc_today()
    child = child_fixture(scope, %{birth_date: Date.add(today, -80)})

    measurement_fixture(scope, child, %{
      "measured_on" => Date.add(today, -70),
      "weight_g" => 3000,
      "height_cm" => 48
    })

    measurement_fixture(scope, child, %{
      "measured_on" => today,
      "weight_g" => 4200,
      "height_cm" => 55
    })

    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")

    assert has_element?(lv, "#weight-chart-ages", "1mo")
    assert has_element?(lv, "#weight-chart-ages", "2mo")
    assert has_element?(lv, "#weight-chart-age-axis")
  end

  test "changing units elsewhere re-renders weight live", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    measurement_fixture(scope, child, %{"weight_g" => 3200, "height_cm" => 50.8})
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")
    assert has_element?(lv, "#latest-weight", "3.2 kg")

    {:ok, _} = Trygg.Accounts.update_user_settings(scope.user, %{unit_system: :imperial})

    html = render(lv)
    refute html =~ "3.2 kg"
    assert has_element?(lv, "#latest-weight", "lb")
    assert has_element?(lv, "#latest-height", "in")
  end

  test "CDC percentile bands and ordinals show when the child's sex is set", %{
    conn: conn,
    scope: scope
  } do
    today = Date.utc_today()
    child = child_fixture(scope, %{sex: :female, birth_date: Date.add(today, -20)})
    p50_w = Trygg.Growth.Percentiles.value_at(child, :weight, 50, today)
    p50_h = Trygg.Growth.Percentiles.value_at(child, :length, 50, today)

    m =
      measurement_fixture(scope, child, %{
        "weight_g" => p50_w,
        "height_cm" => p50_h
      })

    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")

    assert has_element?(lv, "#latest-weight", "50th")
    assert has_element?(lv, "#latest-height", "50th")
    assert has_element?(lv, "#latest-weight-percentile", "percentile")
    assert has_element?(lv, "#latest-height-percentile", "percentile")
    assert has_element?(lv, "#weight-chart-bands")
    assert has_element?(lv, "#height-chart-bands")
    assert has_element?(lv, "#percentile-source", "girls")
    refute has_element?(lv, "#percentile-hint")

    lv |> element("#weight-chart-point-#{m.id} [phx-click]") |> render_click()
    assert has_element?(lv, "#weight-chart-caption", "50th")
  end

  test "a preterm baby's percentiles use corrected age", %{conn: conn, scope: scope} do
    today = Date.utc_today()
    # Born 12 weeks ago at 32+0: corrected age is 4 weeks.
    child =
      child_fixture(scope, %{
        sex: :female,
        birth_date: Date.add(today, -84),
        gestation_weeks: 32
      })

    # 44+0 weeks postmenstrual: scored on INTERGROWTH-21st.
    p50_w = Trygg.Growth.Percentiles.value_at(child, :weight, 50, today)
    measurement_fixture(scope, child, %{"weight_g" => p50_w})

    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")

    assert has_element?(lv, "#latest-weight-percentile", "50th")
    assert has_element?(lv, "#percentile-source", "corrected age (born at 32+0 weeks)")
    assert has_element?(lv, "#corrected-age", "corrected age 0mo 28d · 44+0 weeks postmenstrual")
    assert has_element?(lv, "#weight-chart-band-source", "INTERGROWTH-21st 5th–95th")
    refute has_element?(lv, "#percentile-hint")
  end

  test "an early baby's percentiles can switch between corrected and actual age", %{
    conn: conn,
    scope: scope
  } do
    today = Date.utc_today()

    child =
      child_fixture(scope, %{
        sex: :female,
        birth_date: Date.add(today, -84),
        gestation_weeks: 32
      })

    # 44+0 weeks postmenstrual: scored on INTERGROWTH-21st.
    p50_w = Trygg.Growth.Percentiles.value_at(child, :weight, 50, today)
    measurement_fixture(scope, child, %{"weight_g" => p50_w})

    actual =
      Trygg.Growth.Percentiles.percentile(Child.uncorrected(child), :weight, p50_w, today)
      |> Trygg.Growth.Percentiles.format_percentile()

    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")

    assert has_element?(lv, "#age-basis-corrected[aria-pressed='true']")
    assert has_element?(lv, "#latest-weight-percentile", "50th")

    lv |> element("#age-basis-actual") |> render_click()

    assert has_element?(lv, "#age-basis-actual[aria-pressed='true']")
    assert has_element?(lv, "#latest-weight-percentile", actual)
    assert has_element?(lv, "#percentile-actual-age", "32+0 weeks")
    refute has_element?(lv, "#percentile-source", "corrected")
    refute has_element?(lv, "#corrected-age")

    lv |> element("#age-basis-corrected") |> render_click()
    assert has_element?(lv, "#latest-weight-percentile", "50th")
    refute has_element?(lv, "#percentile-actual-age")
  end

  test "a chart spanning 64 weeks names both standards and marks the handover", %{
    conn: conn,
    scope: scope
  } do
    today = Date.utc_today()

    # Born at 32+0 240 days ago: 64+0 weeks was 16 days ago.
    child =
      child_fixture(scope, %{sex: :female, birth_date: Date.add(today, -240), gestation_weeks: 32})

    measurement_fixture(scope, child, %{measured_on: Date.add(today, -240), weight_g: 1500.0})
    measurement_fixture(scope, child, %{measured_on: today, weight_g: 7200.0})

    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")

    assert has_element?(lv, "#weight-chart-band-source", "INTERGROWTH-21st → CDC")
    assert has_element?(lv, "#weight-chart-handover")

    lv |> element("#age-basis-actual") |> render_click()

    assert has_element?(lv, "#weight-chart-band-source", "CDC 5th–95th")
    refute has_element?(lv, "#weight-chart-band-source", "INTERGROWTH")
    refute has_element?(lv, "#weight-chart-handover")
  end

  test "the age toggle only shows for babies born early", %{conn: conn, scope: scope} do
    today = Date.utc_today()
    child = child_fixture(scope, %{sex: :male, birth_date: Date.add(today, -60)})

    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")
    refute has_element?(lv, "#age-basis")
  end

  test "before a preterm baby's term date, shows INTERGROWTH-21st percentiles", %{
    conn: conn,
    scope: scope
  } do
    today = Date.utc_today()

    child =
      child_fixture(scope, %{sex: :male, birth_date: Date.add(today, -10), gestation_weeks: 30})

    measurement_fixture(scope, child, %{"weight_g" => 1800})

    expected =
      child
      |> Trygg.Growth.Percentiles.percentile(:weight, 1800, today)
      |> Trygg.Growth.Percentiles.format_percentile()

    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")

    assert has_element?(lv, "#latest-weight-percentile", expected)
    assert has_element?(lv, "#weight-chart-bands")
    assert has_element?(lv, "#percentile-source", "INTERGROWTH-21st")
    assert has_element?(lv, "#corrected-age", "31+3 weeks postmenstrual")
    refute has_element?(lv, "#percentile-hint")
  end

  test "a baby still under 27 weeks explains when percentiles begin", %{
    conn: conn,
    scope: scope
  } do
    today = Date.utc_today()

    child =
      child_fixture(scope, %{sex: :male, birth_date: Date.add(today, -5), gestation_weeks: 25})

    measurement_fixture(scope, child, %{"weight_g" => 800})
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")

    assert has_element?(lv, "#percentile-hint", "25+0 weeks")
    assert has_element?(lv, "#percentile-hint", "27 weeks")
    refute has_element?(lv, "#latest-weight-percentile")
  end

  test "unspecified sex keeps measurements but hides CDC bands", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    measurement_fixture(scope, child, %{"weight_g" => 3200, "height_cm" => 50})
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")

    assert has_element?(lv, "#weight-chart svg")
    refute has_element?(lv, "#weight-chart-bands")
    assert has_element?(lv, "#percentile-hint")
    refute has_element?(lv, "#percentile-source")
    refute has_element?(lv, "#latest-weight-percentile")
    refute has_element?(lv, "#latest-height-percentile")
  end

  describe "weight gain card" do
    test "shows an empty state until there are two weights", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")
      assert has_element?(lv, "#weight-gain-card")
      assert has_element?(lv, "#weight-gain-empty", "Log a weight")

      measurement_fixture(scope, child, %{"weight_g" => 4000})
      {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")
      assert has_element?(lv, "#weight-gain-empty", "another weight")
    end

    test "reports the rate, the hold-percentile expectation and percentile movement", %{
      conn: conn,
      scope: scope
    } do
      today = Date.utc_today()
      child = child_fixture(scope, %{sex: :male, birth_date: Date.add(today, -70)})
      earlier = Date.add(today, -21)
      p50_then = Trygg.Growth.Percentiles.value_at(child, :weight, 50, earlier)
      p50_now = Trygg.Growth.Percentiles.value_at(child, :weight, 50, today)

      measurement_fixture(scope, child, %{"weight_g" => p50_then, "measured_on" => earlier})
      measurement_fixture(scope, child, %{"weight_g" => p50_now})

      {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")

      assert has_element?(lv, "#weight-gain-rate", "/week")
      assert has_element?(lv, "#weight-gain-expected", "50th percentile")
      assert has_element?(lv, "#weight-gain-percentile", "50th")
      refute has_element?(lv, "#weight-gain-guide")
      refute has_element?(lv, "#weight-gain-newborn")
    end

    test "a newborn without a birth-day weight is prompted to add one", %{
      conn: conn,
      scope: scope
    } do
      today = Date.utc_today()
      dob = Date.add(today, -5)
      child = child_fixture(scope, %{birth_date: dob})

      {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")
      assert has_element?(lv, "#birth-weight-prompt")

      lv |> element("#birth-weight-prompt button") |> render_click()

      assert has_element?(
               lv,
               "#growth-form input[name='measurement[measured_on]'][value='#{dob}']"
             )
    end

    test "newborn loss and regain are summarised once there is a birth weight", %{
      conn: conn,
      scope: scope
    } do
      today = Date.utc_today()
      dob = Date.add(today, -16)
      child = child_fixture(scope, %{birth_date: dob})

      measurement_fixture(scope, child, %{"weight_g" => 3500, "measured_on" => dob})
      measurement_fixture(scope, child, %{"weight_g" => 3200, "measured_on" => Date.add(dob, 3)})
      measurement_fixture(scope, child, %{"weight_g" => 3550})

      {:ok, lv, _html} = live(conn, ~p"/c/#{child}/vitals")

      refute has_element?(lv, "#birth-weight-prompt")
      assert has_element?(lv, "#weight-gain-newborn", "Born 3.5 kg")
      assert has_element?(lv, "#weight-gain-newborn", "−8.6%")
      assert has_element?(lv, "#weight-gain-newborn", "back to birth weight on day 16")
      assert has_element?(lv, "#weight-gain-guide")
    end
  end
end
