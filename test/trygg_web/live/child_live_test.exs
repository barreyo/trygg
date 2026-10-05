defmodule TryggWeb.ChildLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.FamiliesFixtures

  alias Trygg.Families
  alias Trygg.Families.Child

  setup :register_and_log_in_user

  test "lists the current user's children with their role", %{conn: conn, scope: scope} do
    child = child_fixture(scope)
    {:ok, _lv, html} = live_loaded(conn, ~p"/children")
    assert html =~ child.name
    assert html =~ "owner"
  end

  test "creating a child adds an owner membership and opens the dashboard", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, _html} = live_loaded(conn, ~p"/children/new")

    {:error, {:live_redirect, %{to: path}}} =
      lv
      |> form("#child-form", child: %{name: "Pip", timezone: "Etc/UTC"})
      |> render_submit()

    assert [child] = Families.list_children(scope)
    assert child.name == "Pip"
    assert child.role == :owner
    assert path == ~p"/c/#{child}"
  end

  test "a new child can join a family the user owns", %{conn: conn, scope: scope} do
    first = child_fixture(scope)
    member = Trygg.AccountsFixtures.user_fixture()
    membership_fixture(first, member, :caregiver)

    {:ok, lv, _html} = live_loaded(conn, ~p"/children/new")
    assert has_element?(lv, "#child-family option[value='new'][selected]")
    assert has_element?(lv, "#child-family option[value='#{first.family_id}']")

    {:error, {:live_redirect, _}} =
      lv
      |> form("#child-form",
        child: %{name: "Second", timezone: "Etc/UTC"},
        family_id: to_string(first.family_id)
      )
      |> render_submit()

    second = Enum.find(Families.list_children(scope), &(&1.name == "Second"))
    assert second.family_id == first.family_id
    assert Families.member_role(Trygg.Accounts.Scope.for_user(member), second) == :caregiver
  end

  test "the family choice is only offered when there's a family to join", %{conn: conn} do
    {:ok, lv, _html} = live_loaded(conn, ~p"/children/new")
    refute has_element?(lv, "#child-family")
  end

  test "a child is added to a new family by default", %{conn: conn, scope: scope} do
    first = child_fixture(scope)
    {:ok, lv, _html} = live_loaded(conn, ~p"/children/new")

    {:error, {:live_redirect, _}} =
      lv |> form("#child-form", child: %{name: "Solo", timezone: "Etc/UTC"}) |> render_submit()

    solo = Enum.find(Families.list_children(scope), &(&1.name == "Solo"))
    assert solo.family_id != first.family_id
  end

  test "records how early a child was born", %{conn: conn, scope: scope} do
    child = child_fixture(scope, %{birth_date: Date.add(Date.utc_today(), -30)})
    {:ok, lv, _html} = live_loaded(conn, ~p"/children/#{child}/edit")

    {:error, {:live_redirect, _}} =
      lv
      |> form("#child-form", child: %{gestation_weeks: "31", gestation_extra_days: "4"})
      |> render_submit()

    assert Families.get_child!(scope, child.id).gestational_age_days == 221

    {:ok, lv, _html} = live_loaded(conn, ~p"/children/#{child}/edit")
    assert has_element?(lv, "#child_gestation_weeks option[selected][value='31']")
    assert has_element?(lv, "#child_gestation_extra_days option[selected][value='4']")
  end

  test "the vitamin D reminder can be turned on and off", %{conn: conn, scope: scope} do
    child = child_fixture(scope)
    refute child.vitamin_d_reminder

    {:ok, lv, _html} = live_loaded(conn, ~p"/children/#{child}/edit")
    assert has_element?(lv, "#vitamin-d-help")

    {:error, {:live_redirect, _}} =
      lv |> form("#child-form", child: %{vitamin_d_reminder: "true"}) |> render_submit()

    assert Families.get_child!(scope, child.id).vitamin_d_reminder

    {:ok, lv, _html} = live_loaded(conn, ~p"/children/#{child}/edit")

    {:error, {:live_redirect, _}} =
      lv |> form("#child-form", child: %{vitamin_d_reminder: "false"}) |> render_submit()

    refute Families.get_child!(scope, child.id).vitamin_d_reminder
  end

  test "the list updates live when a child is added from another session", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, html} = live_loaded(conn, ~p"/children")
    refute html =~ "Newbie"

    {:ok, _} = Families.create_child(scope, %{name: "Newbie", timezone: "Etc/UTC"})

    assert render(lv) =~ "Newbie"
  end

  test "the list reflects a live rename by a co-owner", %{conn: conn, scope: scope} do
    child = child_fixture(scope)
    {:ok, lv, html} = live_loaded(conn, ~p"/children")
    assert html =~ child.name

    {:ok, _} = Families.update_child(scope, child, %{name: "Pipkin"})

    assert render(lv) =~ "Pipkin"
    refute render(lv) =~ child.name
  end

  test "can add a child that hasn't been born yet", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live_loaded(conn, ~p"/children/new")

    lv |> element("#child-form button[phx-value-status='expecting']") |> render_click()

    due = Date.add(Date.utc_today(), 40)

    {:error, {:live_redirect, %{to: path}}} =
      lv
      |> form("#child-form",
        child: %{name: "Sprout", timezone: "Etc/UTC", expected_birth_date: Date.to_iso8601(due)}
      )
      |> render_submit()

    assert [child] = Families.list_children(scope)
    assert child.name == "Sprout"
    assert child.expected_birth_date == due
    assert Child.expecting?(child)
    assert path == ~p"/c/#{child}"
  end

  test "the expecting dashboard shows the practice banner", %{conn: conn, scope: scope} do
    {:ok, child} =
      Families.create_child(scope, %{
        name: "Bean",
        timezone: "Etc/UTC",
        expected_birth_date: Date.add(Date.utc_today(), 20)
      })

    {:ok, _lv, html} = live_loaded(conn, ~p"/c/#{child}")
    assert html =~ "Expecting Bean"
    assert html =~ "just practice"
    assert html =~ "Bean has arrived"
  end

  test "marking an expecting child as arrived clears the practice log", %{
    conn: conn,
    scope: scope
  } do
    {:ok, child} =
      Families.create_child(scope, %{
        name: "Bean",
        timezone: "Etc/UTC",
        expected_birth_date: Date.add(Date.utc_today(), 20)
      })

    entry = Trygg.LogFixtures.entry_fixture(scope, child, %{type: :diaper})

    {:ok, lv, html} = live_loaded(conn, ~p"/children/#{child}/edit?arrived=1")
    assert html =~ "Birth date"

    {:error, {:live_redirect, %{to: path}}} =
      lv
      |> form("#child-form", child: %{birth_date: Date.to_iso8601(Date.utc_today())})
      |> render_submit()

    assert path == ~p"/c/#{child}"

    born = Families.get_child!(scope, child.id)
    refute Child.expecting?(born)
    assert born.birth_date == Date.utc_today()
    assert Trygg.Repo.get(Trygg.Log.Entry, entry.id) == nil
  end

  test "the edit form can move a born child into practice mode", %{conn: conn, scope: scope} do
    child = child_fixture(scope, %{birth_date: Date.add(Date.utc_today(), -30)})
    entry = Trygg.LogFixtures.entry_fixture(scope, child, %{type: :diaper})

    {:ok, lv, _html} = live_loaded(conn, ~p"/children/#{child}/edit")

    lv |> element("#child-form button[phx-value-status='expecting']") |> render_click()

    due = Date.add(Date.utc_today(), 25)

    {:error, {:live_redirect, %{to: path}}} =
      lv
      |> form("#child-form", child: %{expected_birth_date: Date.to_iso8601(due)})
      |> render_submit()

    assert path == ~p"/c/#{child}"

    updated = Families.get_child!(scope, child.id)
    assert Child.expecting?(updated)
    assert updated.birth_date == nil
    assert updated.expected_birth_date == due
    # Data is retained — it just becomes practice data.
    assert Trygg.Repo.get(Trygg.Log.Entry, entry.id) != nil
  end

  test "editing renames the child", %{conn: conn, scope: scope} do
    child = child_fixture(scope)
    {:ok, lv, _html} = live_loaded(conn, ~p"/children/#{child}/edit")

    lv
    |> form("#child-form", child: %{name: "Renamed"})
    |> render_submit()

    assert Families.get_child!(scope, child.id).name == "Renamed"
  end

  test "owners can reach the edit form from the list", %{conn: conn, scope: scope} do
    child = child_fixture(scope)
    {:ok, lv, _html} = live_loaded(conn, ~p"/children")

    {:ok, _edit_lv, html} =
      lv
      |> element("#edit-child-#{child.id}")
      |> render_click()
      |> follow_redirect(conn, ~p"/children/#{child}/edit")

    assert html =~ "Edit #{child.name}"
  end

  test "the edit form leads back to the child's page", %{conn: conn, scope: scope} do
    child = child_fixture(scope)
    {:ok, lv, _html} = live_loaded(conn, ~p"/children/#{child}/edit")

    assert has_element?(lv, "header a[aria-label=Back][href='#{~p"/c/#{child}"}']")
    assert has_element?(lv, "#child-form a[href='#{~p"/c/#{child}"}']", "Cancel")
  end

  test "caregivers can't edit a child they don't own", %{conn: conn} do
    %{child: child, member: member} = shared_child_fixture(:caregiver)
    conn = log_in_user(conn, member)

    {:ok, lv, _html} = live_loaded(conn, ~p"/children")
    refute has_element?(lv, "#edit-child-#{child.id}")

    assert {:error, {:live_redirect, %{to: path, flash: flash}}} =
             live(conn, ~p"/children/#{child}/edit")

    assert path == ~p"/c/#{child}"
    assert flash["error"] =~ "owners can edit"
  end
end
