defmodule TryggWeb.Api.ChildController do
  @moduledoc """
  `GET /api/v1/children` and `GET /api/v1/children/:id` — the children in the
  token's family.
  """
  use TryggWeb, :controller

  alias Trygg.Families

  action_fallback TryggWeb.Api.FallbackController

  def index(conn, _params) do
    render(conn, :index, children: Families.list_children(conn.assigns.current_scope))
  end

  def show(conn, %{"id" => id}) do
    render(conn, :show, child: Families.get_child!(conn.assigns.current_scope, id))
  end
end
