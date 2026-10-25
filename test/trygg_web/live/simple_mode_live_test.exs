defmodule TryggWeb.SimpleModeLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.AccountsFixtures
  import Trygg.FamiliesFixtures

  alias Trygg.{Families, Log}

  setup do
    %{owner_scope: owner, child: child, member: member, member_scope: scope} =
      shared_child_fixture(:simple)

    %{conn: log_in_user(build_conn(), member), owner: owner, child: child, scope: scope}
  end

  describe "Today in simple mode" do
    test "shows only the bottle and the diaper, with no tab bar or extras", %{
      conn: conn,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      assert has_element?(lv, "#glance-feed")
      assert has_element?(lv, "#glance-diaper")
      assert has_element?(lv, "#entries")

      for id <-
            ~w(#glance-sleep #customize-home #bottom-nav #side-nav #today-devices #home-notices) do
        refute has_element?(lv, id)
      end

      refute render(lv) =~ "Log from earlier"
      refute render(lv) =~ "Full log"
    end

    test "even when the child's Today is arranged without them", %{
      conn: conn,
      owner: owner,
      child: child
    } do
      {:ok, _} = Families.update_child(owner, child, %{tracked_types: [:sleep]})

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      assert has_element?(lv, "#glance-feed")
      assert has_element?(lv, "#glance-diaper")
      refute has_element?(lv, "#glance-sleep")
    end

    test "the menu is down to the person's own pages", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      assert has_element?(lv, "#app-menu-preferences")
      assert has_element?(lv, "#app-menu-log-out")
      refute has_element?(lv, "#app-menu-sharing")
      refute has_element?(lv, "#app-menu-devices")
      refute has_element?(lv, "#app-menu-children")
    end

    test "a diaper logs with one tap, as it happens", %{conn: conn, child: child, scope: scope} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      render_click(lv, "quick", %{"kind" => "diaper_poo"})

      assert [%{type: :diaper, data: %{"kind" => "poo"}} = entry] =
               Log.recent_entries(scope, child)

      assert DateTime.diff(DateTime.utc_now(), entry.started_at) < 5
    end

    test "the bottle sheet is just an amount, and saves it now", %{
      conn: conn,
      child: child,
      scope: scope
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      lv |> element("#log-bottle") |> render_click()

      assert has_element?(lv, "#simple-bottle-form #bottle-amount")
      refute has_element?(lv, "#simple-bottle-form input[type=datetime-local]")
      refute has_element?(lv, "#simple-bottle-form input[name='entry[note]']")
      refute has_element?(lv, "#simple-bottle-form select")
      refute has_element?(lv, "#simple-bottle-form input[type=file]")

      lv |> form("#simple-bottle-form", entry: %{amount: "90"}) |> render_submit()

      refute has_element?(lv, "#simple-bottle-form")
      assert [%{type: :feeding, data: data} = entry] = Log.recent_entries(scope, child)
      assert data["amount_ml"] == 90.0
      assert DateTime.diff(DateTime.utc_now(), entry.started_at) < 5
    end

    test "a bottle without an amount isn't saved", %{conn: conn, child: child, scope: scope} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      lv |> element("#log-bottle") |> render_click()
      lv |> form("#simple-bottle-form", entry: %{amount: "0"}) |> render_submit()

      assert Log.recent_entries(scope, child) == []
    end

    test "the next bottle starts from the last one's amount and contents", %{
      conn: conn,
      owner: owner,
      child: child,
      scope: scope
    } do
      {:ok, _} =
        Log.create_entry(owner, child, :feeding, %{
          "data" => %{"amount_ml" => 120, "bottle_contents" => "expressed"}
        })

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      lv |> element("#log-bottle") |> render_click()
      lv |> form("#simple-bottle-form") |> render_submit()

      assert [%{data: data}, _] = Log.recent_entries(scope, child)
      assert data["amount_ml"] == 120.0
      assert data["bottle_contents"] == "expressed"
    end

    test "recent is the last few bottles and diapers, to read only", %{
      conn: conn,
      owner: owner,
      child: child
    } do
      for _ <- 1..4, do: Log.create_entry(owner, child, :diaper, %{"data" => %{"kind" => "pee"}})

      for _ <- 1..4,
          do: Log.create_entry(owner, child, :feeding, %{"data" => %{"amount_ml" => 60}})

      {:ok, _} = Log.start_timer(owner, child, :sleep)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      assert lv
             |> element("#entries")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("[id^=entries-]")
             |> Enum.count() == 5

      refute has_element?(lv, "#entries [role=button]")
    end

    test "a change by another caregiver shows up live", %{conn: conn, owner: owner, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      {:ok, _} = Log.create_entry(owner, child, :diaper, %{"data" => %{"kind" => "mixed"}})

      assert has_element?(lv, "#entries [id^=entries-]")
    end
  end

  describe "everything else is closed" do
    test "child pages other than Today send them back to it", %{conn: conn, child: child} do
      for path <- ~w(sleep log vitals reports caregivers devices sleep/plan) do
        assert {:error, {:redirect, %{to: to}}} = live(conn, "/c/#{child.id}/#{path}")
        assert to == ~p"/c/#{child}"
      end

      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/children/#{child}/edit")
      assert to == ~p"/c/#{child}"
    end

    test "the reports PDF is forbidden", %{conn: conn, child: child} do
      conn = get(conn, ~p"/c/#{child}/reports.pdf")
      assert response(conn, 403)
    end
  end

  describe "changing role" do
    test "an owner moving a caregiver into simple mode switches their open screen", %{
      owner: owner,
      child: child
    } do
      caregiver = user_fixture()
      membership = membership_fixture(child, caregiver, :caregiver)
      conn = log_in_user(build_conn(), caregiver)

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      assert has_element?(lv, "#glance-sleep")

      {:ok, _} = Families.update_member_role(owner, child, membership, :simple)

      assert_redirect(lv, ~p"/c/#{child}")
    end

    test "an owner can't be put in simple mode as the last owner", %{owner: owner, child: child} do
      [owner_membership] =
        owner |> Families.list_members(child) |> Enum.filter(&(&1.role == :owner))

      assert {:error, :last_owner} =
               Families.update_member_role(owner, child, owner_membership, :simple)
    end
  end
end
