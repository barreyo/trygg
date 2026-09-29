defmodule TryggWeb.ReportPdfHTMLTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest, only: [render_component: 2]
  import Trygg.FamiliesFixtures
  import Trygg.GrowthFixtures
  import Trygg.LogFixtures

  alias Trygg.Families.Child
  alias Trygg.Reports
  alias TryggWeb.ReportPdfHTML

  setup do
    scope = Trygg.AccountsFixtures.user_scope_fixture()

    child =
      child_fixture(scope, %{
        name: "Astrid",
        sex: :female,
        birth_date: Date.add(Date.utc_today(), -70),
        timezone: midday_timezone()
      })

    %{scope: scope, child: child}
  end

  defp render(scope, child, window \\ 30) do
    export = Reports.export(scope, child, window)

    html =
      render_component(&ReportPdfHTML.report/1,
        child: child,
        unit_system: :metric,
        export: export
      )

    LazyHTML.from_fragment(html)
  end

  defp has?(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.any?()

  defp text(doc, selector) do
    doc |> LazyHTML.query(selector) |> LazyHTML.text()
  end

  test "renders every section for a child with sleep, feeds, diapers and growth", %{
    scope: scope,
    child: child
  } do
    today = Child.local_today(child)
    sleep_days(scope, child, 5)
    feed_days(scope, child, 4, ml: 120)
    diaper_days(scope, child, 4, every_hours: 4)

    measurement_fixture(scope, child, %{
      "weight_g" => 4200.0,
      "height_cm" => 54.0,
      "measured_on" => Date.add(today, -14)
    })

    measurement_fixture(scope, child, %{
      "weight_g" => 4700.0,
      "height_cm" => 56.0,
      "measured_on" => today
    })

    doc = render(scope, child)

    assert text(doc, "#pdf-child-name") =~ "Astrid"
    assert text(doc, "#pdf-header") =~ "Girl"
    assert has?(doc, "#pdf-window")

    assert has?(doc, "#pdf-summary")
    assert has?(doc, "#pdf-weight-percentile")
    assert has?(doc, "#pdf-height-percentile")

    assert has?(doc, "#pdf-growth-weight svg")
    assert has?(doc, "#pdf-growth-height svg")
    assert has?(doc, "#pdf-growth-weight-bands")
    assert has?(doc, "#pdf-weight-gain")
    assert doc |> LazyHTML.query("#pdf-measurements tbody tr") |> Enum.count() == 2

    assert has?(doc, "#pdf-sleep-trend svg")
    assert has?(doc, "#pdf-clock svg")
    assert has?(doc, "#pdf-clock-legend")
    assert has?(doc, "#pdf-heat svg")
    assert has?(doc, "#pdf-wake-windows table")
    assert has?(doc, "#pdf-naps table")
    assert has?(doc, "#pdf-week-calendar")

    assert has?(doc, "#pdf-feeding-volume-chart svg")
    assert has?(doc, "#pdf-feeding-kcal-chart svg")
    assert has?(doc, "#pdf-feeding-count-chart svg")
    assert text(doc, "#pdf-feeding-intake") =~ "ml/kg"
    assert text(doc, "#pdf-footer") =~ "0.67 kcal/ml"

    assert has?(doc, "#pdf-diapers-wet-chart svg")

    # Static mode: nothing tappable leaks into the print output.
    refute has?(doc, "[phx-click]")
    refute text(doc, "#pdf-report") =~ "Tap "
  end

  test "charts feed length when diaper changes come just before feeds", %{
    scope: scope,
    child: child
  } do
    # One clock read for both helpers, or a second ticking over between them
    # shifts every gap to 14m59s.
    now = DateTime.utc_now()
    feed_days(scope, child, 5, every_hours: 3, last_hours_ago: 1, now: now)
    diaper_days(scope, child, 5, every_hours: 3, last_hours_ago: 1.25, now: now)

    doc = render(scope, child)

    assert has?(doc, "#pdf-feed-length-chart svg")
    assert text(doc, "#pdf-feed-length-chart-baseline") =~ "average 15m"
    assert text(doc, "#pdf-feed-length-average") =~ "15m"
    assert text(doc, "#pdf-feed-length-trend") =~ "Steady"
    refute has?(doc, "#pdf-feed-length-sparse")
  end

  test "a baby born early gets corrected and actual-age percentiles side by side", %{
    scope: scope,
    child: term_child
  } do
    today = Date.utc_today()

    child =
      child_fixture(scope, %{
        name: "Early",
        sex: :female,
        birth_date: Date.add(today, -84),
        gestation_weeks: 32,
        timezone: "Etc/UTC"
      })

    earlier =
      measurement_fixture(scope, child, %{
        measured_on: Date.add(today, -28),
        weight_g: 3000.0,
        height_cm: 49.0
      })

    at_birth =
      measurement_fixture(scope, child, %{
        measured_on: Date.add(today, -84),
        weight_g: 1600.0,
        height_cm: 41.0
      })

    measurement_fixture(scope, child, %{measured_on: today, weight_g: 4200.0, height_cm: 54.0})

    doc = render(scope, child)

    assert text(doc, "#pdf-weight-percentile") =~ "corrected"
    assert text(doc, "#pdf-height-percentile") =~ "corrected"
    assert text(doc, "#pdf-summary") =~ "on actual age"
    assert text(doc, "#pdf-measurements thead") =~ "Percentile (corr. / actual)"
    assert text(doc, "#pdf-measurement-#{earlier.id}") =~ "corr. 0d"
    # Before 40 weeks: postmenstrual age, and a corrected percentile from the
    # preterm standard rather than a blank.
    birth_row = text(doc, "#pdf-measurement-#{at_birth.id}")
    assert birth_row =~ "32+0 wk"
    refute birth_row =~ "— /"
    assert text(doc, "#pdf-footer") =~ "INTERGROWTH-21st"
    assert text(doc, "#pdf-footer") =~ "using corrected age (born at 32+0 weeks)"
    assert text(doc, "#pdf-footer") =~ "first uses corrected age and the second actual age"
    assert text(doc, "#pdf-header") =~ "at 32+0 weeks"
    assert has?(doc, "#pdf-weight-gain-actual")

    # A term baby keeps the single column.
    measurement_fixture(scope, term_child)
    term_doc = render(scope, term_child)
    refute text(term_doc, "#pdf-measurements thead") =~ "corr."
    assert text(term_doc, "#pdf-weight-percentile") =~ "percentile"
    refute text(term_doc, "#pdf-summary") =~ "actual age"
  end

  test "renders gracefully for a child with no data at all", %{scope: scope, child: child} do
    doc = render(scope, child, :all)

    assert text(doc, "#pdf-child-name") =~ "Astrid"
    assert has?(doc, "#pdf-sleep-sparse")
    assert has?(doc, "#pdf-feeding-sparse")
    assert has?(doc, "#pdf-feed-length-sparse")
    refute has?(doc, "#pdf-feed-length-chart")
    assert text(doc, "#pdf-measurements") =~ "No height or weight"
    refute has?(doc, "#pdf-alerts")
    refute has?(doc, "#pdf-changes")
  end

  test "document/1 wraps the report in a standalone light-theme page", %{
    scope: scope,
    child: child
  } do
    export = Reports.export(scope, child, 7)

    html =
      %{child: child, unit_system: :imperial, export: export}
      |> ReportPdfHTML.document()
      |> IO.iodata_to_binary()

    assert String.starts_with?(html, "<!DOCTYPE html>")
    assert html =~ ~s(data-theme="light")
    assert html =~ "@page { size: A4;"
    assert html =~ ~s(id="pdf-report")
    assert String.ends_with?(html, "</body></html>")
  end
end
