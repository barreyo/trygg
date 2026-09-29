defmodule TryggWeb.LoadingTest do
  use TryggWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Trygg.FamiliesFixtures

  setup :register_and_log_in_user

  setup %{scope: scope} do
    %{child: child_fixture(scope)}
  end

  # {path, skeleton region id, an element that only exists once loaded}
  defp screens(child) do
    [
      {~p"/c/#{child}", "home-status", "#glance-cards"},
      {~p"/c/#{child}/log", "log-entries", "#entries"},
      {~p"/c/#{child}/vitals", "vitals-content", "#vitals-columns"},
      {~p"/c/#{child}/reports", "report-body", "#report-trends"},
      {~p"/c/#{child}/caregivers", "caregivers", "#caregivers ul"},
      {~p"/children", "children", "#children-list"}
    ]
  end

  test "the static render ships a skeleton instead of querying for the data", %{
    conn: conn,
    child: child
  } do
    for {path, region, content} <- screens(child) do
      doc = conn |> get(path) |> html_response(200) |> LazyHTML.from_document()

      assert LazyHTML.query(doc, "##{region}-loading[aria-busy=true]") |> Enum.count() == 1,
             "expected a skeleton on #{path}"

      assert LazyHTML.query(doc, content) |> Enum.empty?(),
             "expected no loaded content on #{path}"
    end
  end

  test "the connected page swaps its skeleton for the content once loaded", %{
    conn: conn,
    child: child
  } do
    for {path, region, content} <- screens(child) do
      {:ok, lv, _html} = live(conn, path)
      render_async(lv)

      assert has_element?(lv, "##{region}"), "expected #{region} on #{path}"
      assert has_element?(lv, content), "expected #{content} on #{path}"
      refute has_element?(lv, "##{region}-loading")
    end
  end

  test "the static render keeps the page chrome", %{conn: conn, child: child} do
    doc = conn |> get(~p"/c/#{child}") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.query(doc, "#bottom-nav") |> Enum.count() == 1
    assert LazyHTML.text(doc) =~ child.name
  end
end
