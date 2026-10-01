defmodule Mix.Tasks.Trygg.DevToken do
  @shortdoc "Issues a family API token for local dev (e.g. for the M5Stack button)"

  @moduledoc """
  Issues a `Trygg.ApiTokens` bearer token for local development and prints it.

      mix trygg.dev_token                      # first user, their first family
      mix trygg.dev_token --email me@example.com --name "M5Stack" --role caregiver

  The secret is only shown once. Dev only — in production, create tokens from a
  child's Sharing page.
  """
  use Mix.Task

  import Ecto.Query

  alias Trygg.Accounts.{Scope, User}
  alias Trygg.{ApiTokens, Families, Repo}

  @switches [email: :string, name: :string, role: :string]

  @impl Mix.Task
  def run(args) do
    if Mix.env() == :prod, do: Mix.raise("mix trygg.dev_token is for local development only")

    Mix.Task.run("app.start")
    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    user = fetch_user(opts[:email])
    scope = Scope.for_user(user)

    family_id =
      case Families.list_children(scope) do
        [child | _] -> child.family_id
        [] -> Mix.raise("#{user.email} has no children; run `mix seed.dev` first")
      end

    attrs = %{"name" => opts[:name] || "M5Stack button", "role" => opts[:role] || "caregiver"}

    case ApiTokens.create_token(scope, family_id, attrs) do
      {:ok, token} ->
        Mix.shell().info("Token for family #{family_id}, issued as #{user.email}:\n")
        Mix.shell().info(token.secret)

      {:error, changeset} ->
        Mix.raise("Could not create token: #{inspect(changeset.errors)}")
    end
  end

  defp fetch_user(nil), do: Repo.one(from u in User, order_by: u.id, limit: 1) || no_user()

  defp fetch_user(email),
    do: Repo.get_by(User, email: email) || Mix.raise("No user with email #{email}")

  defp no_user, do: Mix.raise("No users yet; run `mix seed.dev` first")
end
