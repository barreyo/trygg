defmodule Trygg.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :trygg

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Idempotently pre-seeds the initial caregiver account. Safe to re-run: an
  existing user with the same email is left untouched.

  Run in production with:

      /app/bin/trygg eval Trygg.Release.seed
  """
  def seed do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Trygg.Repo, fn _repo ->
        seed_user("hello@johanbackman.com", "Johan", "Backman")
      end)
  end

  defp seed_user(email, first_name, last_name) do
    alias Trygg.Accounts
    alias Trygg.Repo

    case Accounts.get_user_by_email(email) do
      nil ->
        {:ok, user} =
          Accounts.register_user(%{
            email: email,
            first_name: first_name,
            last_name: last_name
          })

        user =
          user
          |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now(:second))
          |> Repo.update!()

        IO.puts("seeded user #{user.email} (id=#{user.id}, confirmed)")

      user ->
        IO.puts("user #{user.email} already exists (id=#{user.id}) — skipped")
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
