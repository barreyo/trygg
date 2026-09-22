# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :trygg, :scopes,
  user: [
    default: true,
    module: Trygg.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Trygg.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :trygg,
  ecto_repos: [Trygg.Repo],
  generators: [timestamp_type: :utc_datetime]

# Photo storage. Dev/test write to disk (`priv/uploads`); production swaps in
# the S3 adapter (Tigris on Fly) from config/runtime.exs when the bucket env
# vars are set.
config :trygg, Trygg.Storage, adapter: Trygg.Storage.Local

# Use the bundled IANA time-zone database for all DateTime zone math.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Configures the endpoint
config :trygg, TryggWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TryggWeb.ErrorHTML, json: TryggWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Trygg.PubSub,
  live_view: [signing_salt: "P4At/izu"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :trygg, Trygg.Mailer, adapter: Swoosh.Adapters.Local

# Default sender for all outbound mail. Overridden in production from the
# MAIL_FROM env var (see config/runtime.exs). Accepts a bare address or a
# "Name <addr>" string.
config :trygg, :email_from, "Trygg <contact@example.com>"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  trygg: [
    args:
      ~w(js/app.js js/offline.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  trygg: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Scrub secrets from logs (magic-link tokens live in params and URLs).
config :phoenix, :filter_parameters, ["passw", "secret", "token", "auth", "_key", "credential"]

# Passwordless login/register email throttling. Disabled in test.
config :trygg, Trygg.RateLimit,
  enabled: true,
  login_ip: [limit: 10, window_ms: 900_000],
  login_email: [limit: 5, window_ms: 900_000],
  # Wrong-code attempts per email. Codes are 6 digits, so this caps a
  # brute-force at 5 guesses per 15-minute code lifetime.
  login_code: [limit: 5, window_ms: 900_000],
  register_ip: [limit: 5, window_ms: 900_000]

# Background jobs.
#
#   * `shutdown_grace_period` — how long a queue waits for in-flight jobs to
#     finish on SIGTERM. Kept under fly.toml's `kill_timeout` (30s) with room
#     to spare for endpoint + DB pool drain.
#   * `Lifeline` — moves jobs stranded in `executing` (a Fly machine stopped
#     by autoscaling, an OOM, a hard crash) back to `available` so they run
#     again instead of hanging forever.
#   * `Pruner` — trims completed/cancelled/discarded rows; 7 days keeps enough
#     history to debug a bad run.
#   * `Reindexer` — nightly `REINDEX CONCURRENTLY` on `oban_jobs` to release
#     the index bloat that builds up from constant insert/complete/prune.
#
# The `Cron` plugin (weight-check reminder scan) is added in prod only, from
# config/prod.exs — a long-lived dev machine shouldn't be firing the scan.
config :trygg, Oban,
  repo: Trygg.Repo,
  shutdown_grace_period: :timer.seconds(20),
  queues: [reminders: 10, push: 20],
  plugins: [
    {Oban.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Pruner, max_age: {7, :days}},
    Oban.Reindexer
  ]

# Sleep-prediction accuracy ledger: on each sleep write, record the fresh
# nap/bedtime target and reconcile matured ones (`Trygg.Reports.PredictionLedger`).
# Instrumentation only — it does not change what the app predicts. Off in test
# (call `PredictionLedger.track/2` directly).
config :trygg, Trygg.Reports, track_predictions: true

# Web Push (installed-PWA notifications). `sender` is the delivery adapter
# (`Trygg.Push.Sender.Test` in test). Push also needs a VAPID keypair — set
# below for dev/test, from env in config/runtime.exs for prod — and is a
# no-op whenever that keypair is missing.
config :trygg, Trygg.Push,
  enabled: true,
  sender: Trygg.Push.Sender.WebPush

# VAPID identity for Web Push. Generate a real keypair with
# `mix generate.vapid.keys`; production overrides these from the
# VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY / VAPID_SUBJECT env vars
# (see config/runtime.exs). The keys here are a throwaway pair, fine for
# local dev and tests only.
config :web_push_elixir,
  vapid_public_key:
    "BPXt7ShXQP2Dix2YKNI0kWwYuNOhyKdYbCwQsBOpKTGlo2QNTcXpb91ZtLvpZJoKZMOVWMjiLhza3W2teg7NW_8",
  vapid_private_key: "N0s4TQIKC5at8fWxDKKCfW4ueE0Lyq0iIQN5EFK-NF8",
  vapid_subject: "mailto:hello@johanbackman.com"

# Reports PDF export. `on_demand` launches Chrome per print job (and shuts it
# down afterwards) so environments without a browser still boot. Production
# adds `no_sandbox` and the Chromium path in config/runtime.exs.
#
# `init_timeout`/`checkout_timeout` default to 5s in ChromicPDF, which isn't
# always enough for a cold Chrome launch under `on_demand`; raise them to
# match `timeout` so a slow boot doesn't 500 the request.
config :trygg, ChromicPDF,
  on_demand: true,
  session_pool: [timeout: 20_000, init_timeout: 20_000, checkout_timeout: 20_000],
  chrome_args: "--disable-dev-shm-usage"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
