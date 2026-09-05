defmodule Trygg.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Structured logs for every Oban job/plugin lifecycle event. Job failures
    # land as `error`-level `[Oban]` lines a log-based alert can match on.
    # `encode: false` emits Logger metadata rather than a JSON blob, which
    # reads better with our `$time $metadata[$level] $message` formatter.
    Oban.Telemetry.attach_default_logger(encode: false)

    children = [
      TryggWeb.Telemetry,
      Trygg.Repo,
      Trygg.RateLimit,
      {Oban, Application.fetch_env!(:trygg, Oban)},
      {DNSCluster, query: Application.get_env(:trygg, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Trygg.PubSub},
      # Configured `on_demand`, so Chrome only starts when a PDF is requested.
      {ChromicPDF, Application.get_env(:trygg, ChromicPDF, [])},
      # Start to serve requests, typically the last entry
      TryggWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Trygg.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TryggWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
