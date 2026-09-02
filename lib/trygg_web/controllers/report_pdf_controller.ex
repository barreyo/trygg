defmodule TryggWeb.ReportPdfController do
  @moduledoc """
  `GET /c/:id/reports.pdf?window=30` — the Reports tab as a downloadable PDF.

  Sits in the authenticated browser scope, so `current_scope` is already on
  the conn; `Families.get_child!/2` is membership-scoped and 404s for anyone
  who isn't a viewer of the child.
  """
  use TryggWeb, :controller

  require Logger

  alias Trygg.Families
  alias Trygg.Reports
  alias TryggWeb.ReportPdfHTML

  @windows %{"7" => 7, "14" => 14, "30" => 30, "90" => 90, "all" => :all}
  @default_window 30

  def show(conn, %{"id" => id} = params) do
    scope = conn.assigns.current_scope
    child = Families.get_child!(scope, id)
    window = Map.get(@windows, params["window"], @default_window)
    export = Reports.export(scope, child, window)

    html =
      ReportPdfHTML.document(%{
        child: child,
        unit_system: scope.user.unit_system,
        export: export
      })

    case ChromicPDF.print_to_pdf({:html, html}, print_to_pdf: print_options()) do
      {:ok, base64} ->
        send_download(conn, {:binary, Base.decode64!(base64)},
          filename: filename(child, export.today),
          content_type: "application/pdf"
        )

      {:error, reason} ->
        Logger.error("report PDF failed for child #{child.id}: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Couldn't build the PDF right now — please try again.")
        |> redirect(to: ~p"/c/#{child}/reports?#{[view: "trends", window: window]}")
    end
  end

  @doc "\"trygg-<child>-<date>.pdf\" with the name slugged for filesystems."
  def filename(child, %Date{} = date) do
    slug =
      child.name
      |> String.downcase()
      |> String.replace(~r/[^\p{L}\p{N}]+/u, "-")
      |> String.trim("-")

    slug = if slug == "", do: "child", else: slug
    "trygg-#{slug}-#{Date.to_iso8601(date)}.pdf"
  end

  defp print_options do
    %{
      printBackground: true,
      preferCSSPageSize: true,
      displayHeaderFooter: false
    }
  end
end
