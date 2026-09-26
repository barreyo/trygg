defmodule TryggWeb.ReportComponentsTest do
  use TryggWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias TryggWeb.ReportComponents

  defp info(id, title),
    do: %{id: id, severity: :info, title: title, detail: "Long detail.", link: :reports}

  defp note(alerts) do
    render_component(&ReportComponents.alerts_note/1,
      id: "note",
      alerts: alerts,
      navigate: "/c/1/reports?view=trends"
    )
    |> LazyHTML.from_fragment()
  end

  describe "alerts_note/1" do
    test "renders nothing without alerts" do
      assert note([]) |> LazyHTML.query("#note") |> Enum.empty?()
    end

    test "names the first alert, counts the rest and links to Reports, without the detail" do
      doc =
        note([
          info("feeding-check", "Eating more than usual"),
          info("growth-burst", "Sleeping more than usual")
        ])

      link = LazyHTML.query(doc, "a#note")
      assert LazyHTML.attribute(link, "href") == ["/c/1/reports?view=trends"]

      text = LazyHTML.text(link)
      assert text =~ "Eating more than usual"
      assert text =~ "+1 more"
      refute text =~ "Sleeping more than usual"
      refute text =~ "Long detail."
    end

    test "a single alert has no \"more\" count" do
      refute note([info("feeding-check", "Eating more than usual")])
             |> LazyHTML.text() =~ ~r/\+\d+ more/
    end
  end
end
