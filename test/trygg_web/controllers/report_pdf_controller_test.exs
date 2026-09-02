defmodule TryggWeb.ReportPdfControllerTest do
  use TryggWeb.ConnCase

  import Trygg.FamiliesFixtures
  import Trygg.LogFixtures

  alias TryggWeb.ReportPdfController

  setup %{conn: conn} do
    %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
    child = child_fixture(scope, %{name: "Nils Åke", timezone: "Etc/UTC"})
    %{conn: conn, scope: scope, child: child}
  end

  test "redirects to log in when not authenticated", %{child: child} do
    conn = get(build_conn(), ~p"/c/#{child}/reports.pdf")
    assert redirected_to(conn) == ~p"/users/log-in"
  end

  test "404s for a child the user isn't a member of", %{conn: conn} do
    other_child = child_fixture()

    assert_error_sent 404, fn ->
      get(conn, ~p"/c/#{other_child}/reports.pdf?window=30")
    end
  end

  test "filename slugs the child's name and dates the report", %{child: child} do
    assert ReportPdfController.filename(child, ~D[2026-09-02]) == "trygg-nils-åke-2026-09-02.pdf"
    assert ReportPdfController.filename(%{child | name: "!!!"}, ~D[2026-09-02]) =~ "trygg-child-"
  end

  @tag :chrome
  test "streams a PDF attachment for a member", %{conn: conn, scope: scope, child: child} do
    sleep_days(scope, child, 3)
    feed_days(scope, child, 2)

    conn = get(conn, ~p"/c/#{child}/reports.pdf?window=7")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/pdf"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert disposition =~ "trygg-nils"
    assert <<"%PDF", _::binary>> = conn.resp_body
  end
end
