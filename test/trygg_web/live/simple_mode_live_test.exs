defmodule TryggWeb.SimpleModeLiveTest do
  use TryggWeb.ConnCase

  import Phoenix.LiveViewTest
  import Trygg.AccountsFixtures
  import Ecto.Query, only: [from: 2]
  import Trygg.FamiliesFixtures

  alias Trygg.{Families, Log}
  alias Trygg.Families.Child

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
      refute has_element?(lv, "#entries")

      for id <-
            ~w(#glance-sleep #customize-home #bottom-nav #side-nav #today-devices #home-notices) do
        refute has_element?(lv, id)
      end

      refute render(lv) =~ "Log from earlier"
      refute render(lv) =~ "Full log"
    end

    test "the feed card only says when the last feed was", %{
      conn: conn,
      owner: owner,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      assert lv |> element("#glance-feed") |> render() =~ "No feeds yet"

      # Enough feeds in a short while to trip the cluster call-out for everyone else.
      for _ <- 1..4 do
        {:ok, _} = Log.create_entry(owner, child, :feeding, %{"data" => %{"amount_ml" => 90}})
      end

      html = lv |> element("#glance-feed") |> render()
      assert html =~ "just now"

      for text <- ["cluster", "feeds in 2h", "Next", "today", "Bottle ·"] do
        refute html =~ text
      end

      refute has_element?(lv, "#glance-feed .glance-pill")
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

    test "the diaper card says when the last diaper was and what it was, nothing more", %{
      conn: conn,
      owner: owner,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      assert lv |> element("#glance-diaper") |> render() =~ "none yet"

      # A pee with no poo before it: everyone else gets "no poo yet" and the day's counts.
      {:ok, _} = Log.create_entry(owner, child, :diaper, %{"data" => %{"kind" => "pee"}})

      html = lv |> element("#glance-diaper") |> render()
      assert html =~ "just now"
      assert html =~ "Pee"
      refute html =~ "no poo yet"
      refute html =~ ~r/\d+ diapers?/

      # A pee after an earlier poo: no "poo Nh ago" either.
      {:ok, _} = Log.create_entry(owner, child, :diaper, %{"data" => %{"kind" => "poo"}})
      {:ok, _} = Log.create_entry(owner, child, :diaper, %{"data" => %{"kind" => "pee"}})

      html = lv |> element("#glance-diaper") |> render()
      refute html =~ ~r/\bago\b/
      refute html =~ ~r/\d+ diapers?/
      refute html =~ "none today"
    end

    test "nothing alerts: no health call-outs, banners, prompts or toasts", %{
      conn: conn,
      owner: owner,
      child: child
    } do
      # Long enough without a wet diaper that everyone else gets a warning on the card.
      long_ago = DateTime.add(DateTime.utc_now(), -8 * 3600, :second)

      {:ok, _} =
        Log.create_entry(owner, child, :diaper, %{
          "started_at" => long_ago,
          "data" => %{"kind" => "poo"}
        })

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      refute has_element?(lv, ".glance-pill")
      refute has_element?(lv, "#glance-diaper [data-tone=warning]")
      refute has_element?(lv, "#install-prompt")
      refute has_element?(lv, "#push-prompt")
      refute has_element?(lv, "#home-notices")

      # Logging is confirmed by the celebration, not a toast; a failure still says so.
      render_click(lv, "quick", %{"kind" => "diaper_pee"})
      refute has_element?(lv, "#flash-info")

      lv |> element("#log-bottle") |> render_click()
      lv |> form("#simple-bottle-form", entry: %{amount: "0"}) |> render_submit()
      assert has_element?(lv, "#simple-error")
    end

    test "a failure takes over the screen until it is acknowledged", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      refute has_element?(lv, "#simple-error")

      lv |> element("#log-bottle") |> render_click()
      lv |> form("#simple-bottle-form", entry: %{amount: "0"}) |> render_submit()

      # Not the fading toast everyone else gets: a dialog that waits for "OK".
      refute has_element?(lv, "#flash-error")
      assert has_element?(lv, "#simple-error[role=alertdialog] #simple-error-message")
      assert has_element?(lv, "#simple-error-ok")

      lv |> element("#simple-error-ok") |> render_click()
      refute has_element?(lv, "#simple-error")
    end

    test "the diaper logger is just pee and poo", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      assert has_element?(lv, "#log-diaper button[phx-value-kind=diaper_pee]")
      assert has_element?(lv, "#log-diaper button[phx-value-kind=diaper_poo]")
      refute has_element?(lv, "#log-diaper button[phx-value-kind=diaper_mixed]")
    end

    test "the page is marked for larger type, and others aren't", %{
      conn: conn,
      owner: owner,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      assert has_element?(lv, "[data-simple-mode]")

      {:ok, lv, _html} = live_loaded(log_in_user(build_conn(), owner.user), ~p"/c/#{child}")
      refute has_element?(lv, "[data-simple-mode]")
      assert has_element?(lv, "#log-diaper button[phx-value-kind=diaper_mixed]")
    end

    test "a diaper logs with one tap, as it happens", %{conn: conn, child: child, scope: scope} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      render_click(lv, "quick", %{"kind" => "diaper_poo"})

      assert [%{type: :diaper, data: %{"kind" => "poo"}} = entry] =
               Log.recent_entries(scope, child)

      assert DateTime.diff(DateTime.utc_now(), entry.started_at) < 5
    end

    test "the cards only give a relative time, never a clock time", %{
      conn: conn,
      owner: owner,
      child: child
    } do
      {:ok, entry} = Log.create_entry(owner, child, :feeding, %{"data" => %{"amount_ml" => 90}})
      {:ok, diaper} = Log.create_entry(owner, child, :diaper, %{"data" => %{"kind" => "pee"}})

      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      for {id, at} <- [{"#glance-feed", entry.started_at}, {"#glance-diaper", diaper.started_at}] do
        html = lv |> element(id) |> render()
        assert html =~ "just now"
        refute html =~ Child.local_clock(child, at)
      end
    end

    test "logging says what was logged in plain words, and offers to undo it", %{
      conn: conn,
      child: child,
      scope: scope
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      refute has_element?(lv, "#take-back")

      lv |> element("#log-diaper button[phx-value-kind=diaper_poo]") |> render_click()

      assert_push_event(lv, "log-splash", %{kind: "diaper_poo", label: label})
      assert label == "Poo logged"
      assert lv |> element("#take-back-label") |> render() =~ label
      assert has_element?(lv, "#take-back")

      lv |> element("#log-bottle") |> render_click()
      lv |> form("#simple-bottle-form", entry: %{amount: "90"}) |> render_submit()

      assert_push_event(lv, "log-splash", %{kind: "bottle", label: bottle_label})
      assert bottle_label =~ ~r/^Bottle logged · 90/
      assert lv |> element("#take-back-label") |> render() =~ bottle_label
      assert length(Log.recent_entries(scope, child)) == 2
    end

    test "Undo takes back only what was just logged, then says so", %{
      conn: conn,
      child: child,
      scope: scope
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      render_click(lv, "quick", %{"kind" => "diaper_pee"})
      assert [_] = Log.recent_entries(scope, child)
      assert lv |> element("#glance-diaper") |> render() =~ "Pee"

      lv |> element("#take-back") |> render_click()

      assert Log.recent_entries(scope, child) == []
      assert lv |> element("#glance-diaper") |> render() =~ "none yet"
      assert lv |> element("#take-back-label") |> render() =~ "Undone"
      refute has_element?(lv, "#take-back")

      # A second tap (or a stale one) finds nothing to do.
      render_click(lv, "take_back", %{})
      assert has_element?(lv, "#take-back-label")
    end

    test "the offer moves on to the latest log, and lapses", %{conn: conn, child: child} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")

      render_click(lv, "quick", %{"kind" => "diaper_pee"})
      render_click(lv, "quick", %{"kind" => "diaper_poo"})
      assert lv |> element("#take-back-label") |> render() =~ "Poo"

      %{ref: ref} = :sys.get_state(lv.pid).socket.assigns.take_back
      send(lv.pid, {:take_back_expired, ref})
      refute has_element?(lv, "#take-back-label")
    end

    test "too late to undo says so", %{conn: conn, child: child, scope: scope} do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      render_click(lv, "quick", %{"kind" => "diaper_pee"})

      [entry] = Log.recent_entries(scope, child)
      stale = DateTime.add(DateTime.utc_now(), -5 * 60, :second) |> DateTime.truncate(:second)

      Trygg.Repo.update_all(from(e in Log.Entry, where: e.id == ^entry.id),
        set: [inserted_at: stale]
      )

      lv |> element("#take-back") |> render_click()

      assert has_element?(lv, "#simple-error")
      assert [_] = Log.recent_entries(scope, child)
    end

    test "others don't get the plain confirmation or Undo", %{child: child, owner: owner} do
      {:ok, lv, _html} = live_loaded(log_in_user(build_conn(), owner.user), ~p"/c/#{child}")

      render_click(lv, "quick", %{"kind" => "diaper_pee"})

      assert_push_event(lv, "log-splash", payload)
      refute Map.has_key?(payload, :label)
      refute has_element?(lv, "#take-back")
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

    test "there is no recent list, and the cards still follow what others log", %{
      conn: conn,
      owner: owner,
      child: child
    } do
      {:ok, lv, _html} = live_loaded(conn, ~p"/c/#{child}")
      assert lv |> element("#glance-feed") |> render() =~ "No feeds yet"

      {:ok, _} = Log.create_entry(owner, child, :feeding, %{"data" => %{"amount_ml" => 75}})
      {:ok, _} = Log.create_entry(owner, child, :diaper, %{"data" => %{"kind" => "poo"}})

      assert lv |> element("#glance-feed") |> render() =~ "just now"
      assert lv |> element("#glance-diaper") |> render() =~ "Poo"

      refute has_element?(lv, "#entries")
      refute has_element?(lv, "#home-recent")
      refute render(lv) =~ "Recent"
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
