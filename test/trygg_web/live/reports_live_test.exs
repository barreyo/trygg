defmodule TryggWeb.ReportsLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.FamiliesFixtures
  import Trygg.LogFixtures

  alias Trygg.Families
  alias Trygg.Families.Child

  setup %{conn: conn} do
    %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
    child = child_fixture(scope, %{timezone: "Etc/UTC"})
    %{conn: conn, scope: scope, child: child}
  end

  test "the child switcher stays on reports for the other child", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    sibling = child_fixture(scope, %{name: "Sibling"})
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports")

    {:ok, switched, _html} =
      lv
      |> element("#child-switcher-#{sibling.id}")
      |> render_click()
      |> follow_redirect(conn, ~p"/c/#{sibling}/reports")

    assert has_element?(switched, "#child-switcher-trigger", "Sibling")
    assert has_element?(switched, "header", "Reports")
  end

  test "today view renders the calendar and stats", %{
    conn: conn,
    child: child
  } do
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports?view=today")

    assert has_element?(lv, "#report-view")
    assert has_element?(lv, "#view-today")
    assert has_element?(lv, "#report-today")
    assert has_element?(lv, "#today-calendar")
    assert has_element?(lv, "#day-prev")
    assert has_element?(lv, "#day-next")
  end

  test "the sleep section header shows the day/night definition", %{
    conn: conn,
    child: child
  } do
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports?view=trends")

    assert has_element?(lv, "#section-sleep #day-night-def", "08:00")
    assert has_element?(lv, "#section-sleep #day-night-def", "20:00")
    assert has_element?(lv, "#change-day-night")
  end

  test "download PDF link points at the PDF route with the current window", %{
    conn: conn,
    child: child
  } do
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports")

    assert has_element?(lv, ~s(#download-pdf[href="/c/#{child.id}/reports.pdf?window=7"]))
    assert has_element?(lv, "#download-pdf[download]", "Download PDF report")
    assert has_element?(lv, ~s(#download-pdf[phx-hook="DownloadPdf"][aria-busy="false"]))
    assert has_element?(lv, "#download-pdf .loading-spinner")

    assert render_hook(lv, "pdf_failed", %{}) =~ "build the PDF right now"

    lv |> element("#trend-period-30") |> render_click()
    assert has_element?(lv, ~s(#download-pdf[href="/c/#{child.id}/reports.pdf?window=30"]))

    lv |> element("#view-today") |> render_click()
    assert has_element?(lv, ~s(#download-pdf[href="/c/#{child.id}/reports.pdf?window=30"]))
  end

  test "view buttons switch between trends, today, and week", %{conn: conn, child: child} do
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports")

    assert has_element?(lv, "#report-trends")
    assert has_element?(lv, "#view-trends.btn-primary")

    lv |> element("#view-today") |> render_click()
    assert has_element?(lv, "#report-today")
    refute has_element?(lv, "#report-trends")

    lv |> element("#view-week") |> render_click()
    assert has_element?(lv, "#report-week")
    assert has_element?(lv, "#week-calendar")
    refute has_element?(lv, "#report-today")

    lv |> element("#view-trends") |> render_click()
    assert has_element?(lv, "#report-trends")
    refute has_element?(lv, "#report-week")
  end

  test "typical day heatmap shows hour labels, day/night bands, and wake/bed markers", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    today = Child.local_today(child)

    for n <- 0..2 do
      date = Date.add(today, -n)

      entry_fixture(scope, child, %{
        :type => :sleep,
        "started_at" => DateTime.new!(Date.add(date, -1), ~T[20:00:00], "Etc/UTC"),
        "ended_at" => DateTime.new!(date, ~T[07:00:00], "Etc/UTC")
      })
    end

    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports?view=trends")

    assert has_element?(lv, "#sleep-heat")
    assert has_element?(lv, "#sleep-heat-hours", "00:00")
    assert has_element?(lv, "#sleep-heat-hours", "12:00")
    assert has_element?(lv, "#sleep-heat-hours", "24:00")
    assert has_element?(lv, "#sleep-heat-band-day", "Day")
    assert has_element?(lv, "#sleep-heat-band-night-am", "Night")
    assert has_element?(lv, "#sleep-heat-legend", "Usually asleep")
    assert has_element?(lv, "#sleep-heat-markers", "Wake")
    assert has_element?(lv, "#sleep-heat-markers", "Bed")

    lv |> element("#heat-bin-0") |> render_click()
    assert has_element?(lv, "#sleep-heat-caption", "00:00")
    assert has_element?(lv, "#sleep-heat-caption", "asleep")
  end

  test "wake windows table shows time awake before the next sleep", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    today = Child.local_today(child)

    for n <- 0..2 do
      date = Date.add(today, -n)

      entry_fixture(scope, child, %{
        :type => :sleep,
        "started_at" => DateTime.new!(Date.add(date, -1), ~T[20:00:00], "Etc/UTC"),
        "ended_at" => DateTime.new!(date, ~T[07:00:00], "Etc/UTC")
      })

      entry_fixture(scope, child, %{
        :type => :sleep,
        "started_at" => DateTime.new!(date, ~T[10:00:00], "Etc/UTC"),
        "ended_at" => DateTime.new!(date, ~T[11:00:00], "Etc/UTC")
      })
    end

    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports?view=trends")

    assert has_element?(lv, "#wake-windows-table", "After morning")
    assert has_element?(lv, "#wake-windows-table", "Typical")
    refute has_element?(lv, "#wake-windows-table", "0s")
    assert has_element?(lv, "#naps-table", "Nap 1st")
  end

  test "the sleep trend chart zooms and changes period", %{conn: conn, child: child} do
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports?view=trends")

    assert has_element?(lv, "#trend-period-7.btn-primary")
    assert has_element?(lv, "#trend-zoom-in[disabled]")
    refute has_element?(lv, "#trend-zoom-out[disabled]")

    lv |> element("#trend-period-30") |> render_click()
    assert has_element?(lv, "#trend-period-30.btn-primary")
    refute has_element?(lv, "#trend-zoom-in[disabled]")

    lv |> element("#trend-zoom-out") |> render_click()
    assert has_element?(lv, "#trend-period-90.btn-primary")

    lv |> element("#trend-zoom-in") |> render_click()
    assert has_element?(lv, "#trend-period-30.btn-primary")

    lv |> element("#trend-period-all") |> render_click()
    assert has_element?(lv, "#trend-period-all.btn-primary")
    assert has_element?(lv, "#trend-zoom-out[disabled]")
    assert has_element?(lv, "#sleep-trend-legend", "Sleep")
    assert has_element?(lv, "#sleep-trend-legend", "Awake")
  end

  test "tapping a sleep-trend bar selects it, tapping again opens that day", %{
    conn: conn,
    child: child
  } do
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports?view=trends")
    today = Child.local_today(child)
    iso = Date.to_iso8601(today)

    lv |> element("#sleep-bar-#{iso}") |> render_click()
    assert has_element?(lv, "#sleep-trend-caption", Calendar.strftime(today, "%-d %b"))

    lv |> element("#sleep-bar-#{iso}") |> render_click()
    assert has_element?(lv, "#report-today")
    assert has_element?(lv, "#report-today", "Today")
  end

  test "day navigation walks backward and will not go past today", %{conn: conn, child: child} do
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports?view=today")
    assert has_element?(lv, "#day-next[disabled]")

    lv |> element("#day-prev") |> render_click()
    yesterday = Date.add(Child.local_today(child), -1)
    assert has_element?(lv, "#report-today", Calendar.strftime(yesterday, "%-d %b"))
    refute has_element?(lv, "#day-next[disabled]")

    lv |> element("#day-next") |> render_click()
    assert has_element?(lv, "#report-today", "Today")
  end

  test "tapping a week column opens that day in the today view", %{conn: conn, child: child} do
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports?view=week")
    today = Child.local_today(child)
    yesterday = Date.add(today, -1)

    lv |> element("#week-col-#{Date.to_iso8601(yesterday)}") |> render_click()
    assert has_element?(lv, "#report-today")
    assert has_element?(lv, "#report-today", Calendar.strftime(yesterday, "%-d %b"))
  end

  test "the owner can change day and night from the reports sheet", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports")
    lv |> element("#change-day-night") |> render_click()
    assert has_element?(lv, "#day-night-form")

    lv
    |> form("#day-night-form", child: %{day_start: "07:30", night_start: "19:00"})
    |> render_submit()

    updated = Families.get_child!(scope, child.id)
    assert updated.day_start == ~T[07:30:00]
    assert updated.night_start == ~T[19:00:00]
    assert has_element?(lv, "#day-night-def", "07:30")
    assert has_element?(lv, "#day-night-def", "19:00")
    refute has_element?(lv, "#day-night-sheet")
  end

  test "a caregiver cannot see the day/night change control", %{conn: conn} do
    %{child: child, member: member} = shared_child_fixture(:caregiver)
    conn = log_in_user(conn, member)

    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports")
    assert has_element?(lv, "#day-night-def")
    refute has_element?(lv, "#change-day-night")
  end

  test "sleep blocks show up on the today calendar", %{conn: conn, scope: scope, child: child} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    started = DateTime.add(now, -2 * 3600, :second)

    entry =
      entry_fixture(scope, child, %{
        :type => :sleep,
        "started_at" => started,
        "ended_at" => now
      })

    {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports?view=today")
    assert has_element?(lv, "#sleep-#{entry.id}")
  end

  describe "trends: feeding, diapers and changes" do
    test "cards render their empty states without any logs", %{conn: conn, child: child} do
      {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports?view=trends")

      assert has_element?(lv, "#trend-feeding")
      assert has_element?(lv, "#feeding-sparse")
      assert has_element?(lv, "#trend-diapers")
      assert has_element?(lv, "#trend-changes")
      assert has_element?(lv, "#changes-sparse")
      refute has_element?(lv, "#trend-alerts")
      refute has_element?(lv, "#outlook-next-feed")
    end

    test "regular bottles fill the feeding card and the outlook", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      feed_days(scope, child, 3, every_hours: 3, last_hours_ago: 1)

      {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports?view=trends")

      assert has_element?(lv, "#feeding-day-interval", "3h")
      assert has_element?(lv, "#feeding-per-day", "~")
      assert has_element?(lv, "#feeding-per-feed", "~")
      assert has_element?(lv, "#feeding-volume-baseline", "usual")
      assert has_element?(lv, "#outlook-next-feed")
      refute has_element?(lv, "#feeding-sparse")
    end

    test "the feeding card shows the typical-for-age pattern as labelled context", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      # Fixture child is 20 days old → the "1 month" row: 6–8 feeds of 2–4 oz.
      feed_days(scope, child, 3, every_hours: 3, last_hours_ago: 1)

      {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports?view=trends")

      assert has_element?(lv, "#feeding-age-guide", "Typical for age")
      assert has_element?(lv, "#feeding-age-guide", "6–8 feeds of 60–120 ml")
      assert has_element?(lv, "#feeding-age-guide", "cues")
      assert has_element?(lv, "#feeding-per-day", "typical 6–8")
    end

    test "no typical-for-age line without a birth date", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      {:ok, child} = Trygg.Families.update_child(scope, child, %{birth_date: nil})
      feed_days(scope, child, 3, every_hours: 3, last_hours_ago: 1)

      {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports?view=trends")

      assert has_element?(lv, "#trend-feeding")
      refute has_element?(lv, "#feeding-age-guide")
    end

    test "diapers build a baseline and today's count", %{conn: conn, scope: scope, child: child} do
      diaper_days(scope, child, 4, every_hours: 3, last_hours_ago: 1)

      {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports?view=trends")

      assert has_element?(lv, "#diapers-wet-usual", "~8")
      assert has_element?(lv, "#diapers-dirty-usual", "~0")
      assert has_element?(lv, "#diapers-today")
      assert has_element?(lv, "#diapers-wet-baseline", "usual ~8 wet a day")
    end

    test "today's feeds card sums volume and the median gap", %{conn: conn, scope: scope} do
      # Around local midday, so this morning's feeds all land on today.
      child = child_fixture(scope, %{timezone: midday_timezone()})
      feed_days(scope, child, 1, every_hours: 3, last_hours_ago: 1)

      {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports?view=today")
      assert has_element?(lv, "#report-today", "every ~3h")
      assert has_element?(lv, "#report-today", "ml")
    end

    test "a stable three weeks of sleep reports no notable changes", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      sleep_days(scope, child, 20)

      {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports?view=trends")
      assert has_element?(lv, "#changes-none")
      refute has_element?(lv, "#changes-sparse")
    end

    test "a hydration flag shows the alert list on trends", %{
      conn: conn,
      scope: scope,
      child: child
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      entry_fixture(scope, child, %{
        :type => :diaper,
        "started_at" => DateTime.add(now, -8 * 3600, :second)
      })

      entry_fixture(scope, child, %{:type => :feeding, "started_at" => now})

      {:ok, lv, _html} = live(conn, ~p"/c/#{child}/reports?view=trends")
      assert has_element?(lv, "#trend-alerts-no-wet-diaper")
    end
  end
end
