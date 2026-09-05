defmodule Trygg.ObanConfigTest do
  # Guards the Oban wiring so a bad plugin option or a typo'd cron expression
  # fails in CI instead of at boot on the box.
  use ExUnit.Case, async: true

  describe "base config (config/config.exs)" do
    setup do
      %{oban: Application.fetch_env!(:trygg, Oban)}
    end

    test "runs the production-hardening plugins", %{oban: oban} do
      plugins = oban[:plugins]

      assert Enum.any?(plugins, &match?({Oban.Lifeline, _}, &1))
      assert Enum.any?(plugins, &match?({Oban.Pruner, _}, &1))
      assert Enum.member?(plugins, Oban.Reindexer)
    end

    test "keeps the shutdown grace period under fly.toml's kill_timeout", %{oban: oban} do
      # fly.toml: kill_timeout = '30s'. Stay well under it so the endpoint and
      # DB pool still get time to drain after the queues do.
      assert oban[:shutdown_grace_period] <= :timer.seconds(25)
    end

    test "declares the push queue for DeliveryWorker", %{oban: oban} do
      assert Keyword.has_key?(oban[:queues], :push)
    end
  end

  describe "production config (config/prod.exs)" do
    setup do
      config = Config.Reader.read!("config/prod.exs", env: :prod)
      %{plugins: config[:trygg][Oban][:plugins]}
    end

    test "adds the Cron plugin on top of the base plugins", %{plugins: plugins} do
      assert Enum.any?(plugins, &match?({Oban.Lifeline, _}, &1))
      assert Enum.any?(plugins, &match?({Oban.Pruner, _}, &1))
      assert Enum.member?(plugins, Oban.Reindexer)
      assert Enum.any?(plugins, &match?({Oban.Cron, _}, &1))
    end

    test "every crontab entry has a valid expression and a real worker", %{plugins: plugins} do
      {Oban.Cron, opts} = Enum.find(plugins, &match?({Oban.Cron, _}, &1))

      for {expression, worker} <- opts[:crontab] do
        assert {:ok, _} = Oban.Cron.parse(expression)
        assert Code.ensure_loaded?(worker)
        assert function_exported?(worker, :perform, 1), "#{inspect(worker)} is not an Oban worker"
      end
    end
  end
end
