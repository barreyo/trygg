defmodule TryggWeb.SkeletonComponentsTest do
  use TryggWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias TryggWeb.SkeletonComponents

  defp home(assigns) do
    render_component(&SkeletonComponents.home_status_skeleton/1, assigns)
    |> LazyHTML.from_fragment()
  end

  defp cards(doc), do: LazyHTML.query(doc, "[data-skeleton-card]")

  describe "home_status_skeleton/1" do
    test "draws one ghost card per tracked type, in order" do
      doc = home(types: [:sleep, :breastfeeding], can_write: true)

      assert doc |> cards() |> LazyHTML.attribute("data-skeleton-card") == [
               "sleep",
               "breastfeeding"
             ]
    end

    test "defaults to the standard three" do
      assert doc_types(home([])) == ["feeding", "diaper", "sleep"]
    end

    test "the diaper ghost has three buttons, the others one bar" do
      doc = home(types: [:diaper, :feeding], can_write: true)

      assert doc
             |> LazyHTML.query("[data-skeleton-card=diaper] .grid-cols-3 > .skeleton")
             |> Enum.count() == 3

      assert doc |> LazyHTML.query("[data-skeleton-card=feeding] .grid-cols-3") |> Enum.empty?()

      assert doc
             |> LazyHTML.query("[data-skeleton-card=feeding] .skeleton.w-full")
             |> Enum.count() == 1
    end

    test "shows the Log from earlier / Customize row only for writers" do
      assert home(can_write: true) |> LazyHTML.query("#home-skeleton-footer") |> Enum.count() == 1
      assert home(can_write: false) |> LazyHTML.query("#home-skeleton-footer") |> Enum.empty?()
    end

    test "read-only viewers get no action buttons" do
      doc = home(types: [:diaper, :sleep], can_write: false)

      assert doc |> LazyHTML.query(".grid-cols-3") |> Enum.empty?()
      assert doc |> LazyHTML.query("[data-skeleton-card=sleep] .skeleton.w-full") |> Enum.empty?()
    end
  end

  defp doc_types(doc), do: doc |> cards() |> LazyHTML.attribute("data-skeleton-card")
end
