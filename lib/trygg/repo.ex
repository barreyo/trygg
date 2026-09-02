defmodule Trygg.Repo do
  use Ecto.Repo,
    otp_app: :trygg,
    adapter: Ecto.Adapters.Postgres
end
