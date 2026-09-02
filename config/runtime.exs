import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/trygg start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :trygg, TryggWeb.Endpoint, server: true
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # Fly Postgres on the 6PN (*.internal) speaks plaintext. Forcing SSL makes
  # Postgrex fail with "ssl connect: closed". Set DATABASE_SSL=true only when
  # connecting over the public internet.
  ssl =
    if System.get_env("DATABASE_SSL") in ~w(true 1) do
      [verify: :verify_none]
    else
      false
    end

  config :trygg, Trygg.Repo,
    ssl: ssl,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "8080")

  config :trygg, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :trygg, TryggWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    # Accept LiveView sockets from the request host (custom domain or *.fly.dev)
    # after Plug.SSL has rewritten X-Forwarded-Proto / Host.
    check_origin: :conn,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## Configuring the mailer
  #
  # Production email goes through Resend (https://resend.com). Passwordless
  # login is the only way into the app, so a working mailer is required — we
  # raise here rather than silently degrade to a no-op adapter.
  #
  # Set these as release secrets (e.g. `fly secrets set ...`):
  #
  #   * RESEND_API_KEY  – API key from the Resend dashboard ("re_...")
  #   * MAIL_FROM        – sender on a domain verified in Resend. Accepts a
  #                        bare address ("hello@trygg.app") or a named address
  #                        ("Trygg <hello@trygg.app>"). Defaults to the shared
  #                        Resend sandbox sender, which only delivers to the
  #                        account owner — fine for a first smoke test, not
  #                        for real users.
  #
  # The Req-based API client is wired up at compile time in config/prod.exs.
  resend_api_key =
    System.get_env("RESEND_API_KEY") ||
      raise """
      environment variable RESEND_API_KEY is missing.
      Grab one from https://resend.com/api-keys and set it as a release secret.
      """

  config :trygg, Trygg.Mailer,
    adapter: Swoosh.Adapters.Resend,
    api_key: resend_api_key

  config :trygg, :email_from, System.get_env("MAIL_FROM") || "Trygg <onboarding@resend.dev>"

  # Reports PDF export. The release runs as a non-root user on Alpine, where
  # Chrome's sandbox can't start; the HTML we print is our own, so disabling
  # it is fine. CHROME_EXECUTABLE is set in the Dockerfile.
  config :trygg, ChromicPDF,
    on_demand: true,
    no_sandbox: true,
    session_pool: [timeout: 20_000],
    chrome_args: "--disable-dev-shm-usage",
    chrome_executable: System.get_env("CHROME_EXECUTABLE") || "/usr/bin/chromium-browser"
end
