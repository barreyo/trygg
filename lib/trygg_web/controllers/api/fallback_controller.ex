defmodule TryggWeb.Api.FallbackController do
  @moduledoc "Turns the `{:error, _}` results API actions return into JSON responses."
  use TryggWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: TryggWeb.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: TryggWeb.ErrorJSON)
    |> render(:"404")
  end

  def call(conn, {:error, :not_running}) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "entry is not a running timer"}})
  end

  def call(conn, {:error, errors}) when is_map(errors) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: errors})
  end
end
