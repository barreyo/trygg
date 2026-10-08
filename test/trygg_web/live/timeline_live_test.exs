defmodule TryggWeb.TimelineLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.FamiliesFixtures
  import Trygg.LogFixtures

  alias Trygg.Log

  setup %{conn: conn} do
    %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
    %{conn: conn, scope: scope, child: child_fixture(scope)}
  end

  test "the compact child switcher stays on the log for the other child", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    sibling = child_fixture(scope, %{name: "Sibling"})
    {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/log")

    assert has_element?(lv, "#child-switcher-trigger", child.name)

    {:ok, switched, _html} =
      lv
      |> element("#child-switcher-#{sibling.id}")
      |> render_click()
      |> follow_redirect(conn, ~p"/c/#{sibling}/log")

    assert has_element?(switched, "#child-switcher-trigger", "Sibling")
    assert has_element?(switched, "header", "Log")
  end

  test "shows entries and filters by type", %{conn: conn, scope: scope, child: child} do
    entry_fixture(scope, child, type: :feeding)
    entry_fixture(scope, child, type: :diaper)

    {:ok, lv, html} = live_loaded(conn, ~p"/c/#{child}/log")
    assert html =~ "Bottle"
    assert html =~ "diaper"

    filtered = lv |> element("button", "Diapers") |> render_click()
    assert filtered =~ "diaper"
    refute filtered =~ "Bottle"
  end

  test "a type can be narrowed down further", %{conn: conn, scope: scope, child: child} do
    pee = entry_fixture(scope, child, %{:type => :diaper, "data" => %{"kind" => "pee"}})
    poo = entry_fixture(scope, child, %{:type => :diaper, "data" => %{"kind" => "poo"}})

    {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/log")
    refute has_element?(lv, "#log-subfilters")

    lv |> element("#filter-diaper") |> render_click()
    assert has_element?(lv, "#log-subfilters")
    assert has_element?(lv, "#entries-#{pee.id}")
    assert has_element?(lv, "#entries-#{poo.id}")

    lv |> element("#subfilter-poo") |> render_click()
    refute has_element?(lv, "#entries-#{pee.id}")
    assert has_element?(lv, "#entries-#{poo.id}")

    lv |> element("#subfilter-all") |> render_click()
    assert has_element?(lv, "#entries-#{pee.id}")

    # Switching type drops the narrower choice.
    lv |> element("#subfilter-pee") |> render_click()
    lv |> element("#filter-feeding") |> render_click()
    assert has_element?(lv, "#subfilter-formula")
    assert has_element?(lv, "#subfilter-donor")
    refute has_element?(lv, "#subfilter-pee")
  end

  test "feeds can be narrowed to formula or donor milk", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    formula =
      entry_fixture(scope, child, %{
        :type => :feeding,
        "data" => %{"bottle_contents" => "formula", "amount_ml" => 90}
      })

    donor =
      entry_fixture(scope, child, %{
        :type => :feeding,
        "data" => %{"bottle_contents" => "donor", "amount_ml" => 90}
      })

    {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/log")
    lv |> element("#filter-feeding") |> render_click()
    lv |> element("#subfilter-donor") |> render_click()

    assert has_element?(lv, "#entries-#{donor.id}")
    refute has_element?(lv, "#entries-#{formula.id}")
  end

  test "older entries load a page at a time, all the way back", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    now = DateTime.utc_now()

    entries =
      for i <- 1..120 do
        entry_fixture(scope, child, %{
          :type => :diaper,
          "started_at" => DateTime.add(now, -i * 3600 * 6, :second),
          "data" => %{"kind" => "pee"}
        })
      end

    {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/log")
    assert has_element?(lv, "#entries-#{Enum.at(entries, 0).id}")
    refute has_element?(lv, "#entries-#{Enum.at(entries, 99).id}")
    assert has_element?(lv, "#log-load-more")
    refute has_element?(lv, "#log-end")

    lv |> element("#log-load-more") |> render_click()
    assert has_element?(lv, "#entries-#{Enum.at(entries, 99).id}")
    assert has_element?(lv, "#log-load-more")

    lv |> element("#log-load-more") |> render_click()
    assert has_element?(lv, "#entries-#{Enum.at(entries, 119).id}")
    refute has_element?(lv, "#log-load-more")
    assert has_element?(lv, "#log-end")

    # A live update keeps the older pages on screen.
    entry_fixture(scope, child, type: :diaper)
    assert has_element?(lv, "#entries-#{Enum.at(entries, 119).id}")
  end

  test "editing an entry updates its note", %{conn: conn, scope: scope, child: child} do
    entry = entry_fixture(scope, child, type: :diaper)

    {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/log")
    lv |> element(~s([id$="#{entry.id}"])) |> render_click()

    lv
    |> form("#edit-entry-form", entry: %{note: "leaked"})
    |> render_submit()

    assert Log.get_entry!(scope, entry.id).note == "leaked"
  end

  test "deleting an entry removes it", %{conn: conn, scope: scope, child: child} do
    entry = entry_fixture(scope, child, type: :diaper)

    {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/log")
    lv |> element(~s([id$="#{entry.id}"])) |> render_click()
    lv |> element("#edit-entry-delete") |> render_click()

    assert Log.list_entries(scope, child) == []
  end

  test "a photo added while editing shows in the log feed", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    entry = entry_fixture(scope, child, type: :diaper)

    {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/log")
    lv |> element(~s([id$="#{entry.id}"])) |> render_click()

    photo =
      file_input(lv, "#edit-entry-form", :photo, [
        %{name: "p.png", content: tiny_png(), type: "image/png"}
      ])

    assert render_upload(photo, "p.png")
    lv |> form("#edit-entry-form", entry: %{}) |> render_submit()

    updated = Log.get_entry!(scope, entry.id)
    assert updated.photo_key
    assert render(lv) =~ ~p"/c/#{child}/log/#{entry.id}/photo"

    conn = get(conn, ~p"/c/#{child}/log/#{entry.id}/photo")
    assert conn.status == 200
    assert conn.resp_body == tiny_png()
  end

  test "an entry logged by another caregiver shows up live", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/log")
    refute render(lv) =~ "Bottle"

    entry_fixture(scope, child, type: :feeding)

    assert render(lv) =~ "Bottle"
  end

  test "changing units elsewhere re-renders amounts live", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    entry_fixture(scope, child, type: :feeding)

    {:ok, lv, html} = live_loaded(conn, ~p"/c/#{child}/log")
    assert html =~ "90 ml"

    {:ok, _} = Trygg.Accounts.update_user_settings(scope.user, %{unit_system: :imperial})

    html = render(lv)
    refute html =~ "90 ml"
    assert html =~ "oz"
  end

  test "a caregiver loses the log the moment their access is revoked", %{conn: conn} do
    %{owner_scope: owner_scope, child: child, member: member} = shared_child_fixture()
    conn = log_in_user(conn, member)

    {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/log")

    [membership] =
      Trygg.Families.list_members(owner_scope, child)
      |> Enum.filter(&(&1.user_id == member.id))

    {:ok, _} = Trygg.Families.remove_member(owner_scope, child, membership)

    assert_redirect(lv, ~p"/")
  end

  test "an entry logged by an integration says Other, not a person's name", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    {:ok, token} =
      Trygg.ApiTokens.create_token(scope, child.family_id, %{
        name: "Home Assistant",
        role: :caregiver
      })

    {:ok, api_scope} = Trygg.ApiTokens.authenticate(token.secret)
    {:ok, by_api} = Log.create_entry(api_scope, child, :diaper, %{"data" => %{"kind" => "pee"}})
    {:ok, by_me} = Log.create_entry(scope, child, :diaper, %{"data" => %{"kind" => "poo"}})

    {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/log")

    api_row = "#entries-#{by_api.id}"
    assert has_element?(lv, "#{api_row} [data-logged-by=integration]", "Other")
    assert has_element?(lv, "#{api_row} [title='Logged by an integration: Home Assistant']")
    refute render(element(lv, api_row)) =~ scope.user.first_name

    me_row = "#entries-#{by_me.id}"
    refute has_element?(lv, "#{me_row} [data-logged-by=integration]")
    assert has_element?(lv, me_row, Trygg.Accounts.User.capitalize_name(scope.user.first_name))
  end

  test "a forgotten vitamin D drop can be added to a logged bottle", %{
    conn: conn,
    scope: scope,
    child: child
  } do
    {:ok, child} = Trygg.Families.update_child(scope, child, %{vitamin_d_reminder: true})
    entry = entry_fixture(scope, child, %{:type => :feeding})

    {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}/log")
    lv |> element(~s([id$="#{entry.id}"])) |> render_click()
    lv |> form("#edit-entry-form", entry: %{vitamin_d: "true"}) |> render_submit()

    assert %{data: %{"vitamin_d" => true}} = Log.get_entry!(scope, entry.id)
    assert has_element?(lv, "[data-vitamin-d]")
  end
end
