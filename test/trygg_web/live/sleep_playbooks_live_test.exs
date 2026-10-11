defmodule TryggWeb.SleepPlaybooksLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.FamiliesFixtures

  alias Trygg.Families

  defp older_child(scope),
    do: child_fixture(scope, %{birth_date: Date.add(Date.utc_today(), -100)})

  describe "auth and navigation" do
    test "anonymous users are sent to log in", %{conn: conn} do
      child = child_fixture()

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(conn, ~p"/c/#{child}/sleep/playbooks")
    end

    test "a non-member is bounced", %{conn: conn} do
      child = child_fixture()
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => _}}}} =
               live(conn, ~p"/c/#{child}/sleep/playbooks")
    end

    test "is in the Sleep sub-navigation", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      child = older_child(scope)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/playbooks")
      assert has_element?(lv, "#subnav-playbooks[aria-current=page]")

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep")
      assert has_element?(lv, "#subnav-playbooks[href='#{~p"/c/#{child}/sleep/playbooks"}']")
      assert has_element?(lv, "#insights-more[href='#{~p"/c/#{child}/sleep/playbooks"}']")
    end

    test "when sleep isn't tracked it sends you to Today", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      child = child_fixture(scope)
      {:ok, child} = Families.update_tracked_types(scope, child, [:diaper])

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/c/#{child}/sleep/playbooks")
      assert to == ~p"/c/#{child}"
    end
  end

  describe "the page" do
    setup %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      %{conn: conn, scope: scope, child: older_child(scope)}
    end

    test "starts with nothing worth a look, the nap conventions and the playbooks", %{
      conn: conn,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/playbooks")

      assert has_element?(lv, "#findings-none")
      assert has_element?(lv, "#nap-conventions li", "Consistency")
      assert has_element?(lv, "#nap-place-none")
      assert has_element?(lv, "#nap-drop-now")
      assert has_element?(lv, "#playbook-regression summary", "sleep regression")
      assert has_element?(lv, "#playbook-early_morning")
      assert has_element?(lv, "#medical-reflux")
    end

    test "a newborn gets the page too", %{conn: conn, scope: scope} do
      child = child_fixture(scope)
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/playbooks")
      assert has_element?(lv, "#playbooks")
      assert has_element?(lv, "#shift-planner")
    end

    test "the bedtime planner works out the days as the form changes", %{
      conn: conn,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/playbooks")

      lv
      |> form("#shift-form", %{
        "shift" => %{
          "from_bed" => "20:30",
          "to_bed" => "19:30",
          "from_wake" => "",
          "to_wake" => ""
        }
      })
      |> render_change()

      assert has_element?(lv, "#shift-day-1", "20:15")
      assert has_element?(lv, "#shift-day-4", "19:30")
      refute has_element?(lv, "#shift-day-5")
    end

    test "the bedtime planner shifts the wake time too when asked", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/playbooks")

      lv
      |> form("#shift-form", %{
        "shift" => %{
          "from_bed" => "21:00",
          "to_bed" => "20:00",
          "from_wake" => "08:00",
          "to_wake" => "07:00"
        }
      })
      |> render_change()

      assert has_element?(lv, "#shift-day-1", "07:45")
      assert has_element?(lv, "#shift-day-4", "07:00")
    end

    test "the clock change planner gives four evenings in spring and light advice in autumn", %{
      conn: conn,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/playbooks")

      lv
      |> form("#dst-form", %{
        "dst" => %{
          "direction" => "forward",
          "date" => "2027-03-28",
          "bed" => "19:00",
          "wake" => "06:00"
        }
      })
      |> render_change()

      assert has_element?(lv, "#dst-day-1", "18:45")
      assert has_element?(lv, "#dst-day-4", "18:00")
      assert has_element?(lv, "#dst-day-4", "new clock")

      lv
      |> form("#dst-form", %{
        "dst" => %{
          "direction" => "back",
          "date" => "2026-10-25",
          "bed" => "19:00",
          "wake" => "06:00"
        }
      })
      |> render_change()

      refute has_element?(lv, "#dst-table")
      assert has_element?(lv, "#dst-tips li", "bright light")
    end

    test "the travel planner says when to stay on home time and when to use light", %{
      conn: conn,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/playbooks")

      lv
      |> form("#travel-form", %{
        "travel" => %{"hours" => "1", "direction" => "east", "days" => "3"}
      })
      |> render_change()

      assert has_element?(lv, "#travel-keep-home")

      lv
      |> form("#travel-form", %{
        "travel" => %{"hours" => "6", "direction" => "east", "days" => "10"}
      })
      |> render_change()

      refute has_element?(lv, "#travel-keep-home")
      assert has_element?(lv, "#travel-adjust", "6 days")
      assert has_element?(lv, "#travel-tips li", "early morning")
    end

    test "bad planner input doesn't crash the page", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/sleep/playbooks")

      lv
      |> form("#shift-form", %{
        "shift" => %{"from_bed" => "", "to_bed" => "", "from_wake" => "", "to_wake" => ""}
      })
      |> render_change()

      assert has_element?(lv, "#shift-none")

      lv
      |> form("#travel-form", %{
        "travel" => %{"hours" => "x", "direction" => "west", "days" => ""}
      })
      |> render_change()

      assert has_element?(lv, "#travel-planner")
    end
  end
end
