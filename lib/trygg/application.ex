defmodule Trygg.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TryggWeb.Telemetry,
      Trygg.Repo,
      {DNSCluster, query: Application.get_env(:trygg, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Trygg.PubSub},
      # Start a worker by calling: Trygg.Worker.start_link(arg)
      # {Trygg.Worker, arg},
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
