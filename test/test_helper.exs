# `:chrome` tests print a real PDF through headless Chrome. Opt in with
# `mix test --include chrome` where Chrome/Chromium is installed.
ExUnit.start(exclude: [:chrome])
Ecto.Adapters.SQL.Sandbox.mode(Trygg.Repo, :manual)
