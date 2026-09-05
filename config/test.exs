import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :trygg, Trygg.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "trygg_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :trygg, TryggWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "vjRYcDmkHhQJdU6776kxmWg2CbI13zWlrWMmiAdT++Tno7VwqkXQwb9rggaKIBxT",
  server: false

# In test we don't send emails
config :trygg, Trygg.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

config :trygg, Trygg.RateLimit, enabled: false

# Oban runs no queues or cron in test; assert with `Oban.Testing` or call
# `Trygg.Growth.WeightReminders.run/0` directly.
config :trygg, Oban, testing: :manual

# Log photos land in a throwaway tmp dir during the test run.
config :trygg, Trygg.Storage,
  adapter: Trygg.Storage.Local,
  base_dir: Path.expand("../tmp/test_uploads", __DIR__)

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
