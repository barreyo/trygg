defmodule Trygg.RateLimit do
  @moduledoc """
  Process-local sliding-window rate limiter backed by ETS.

  Enough for a single Fly machine. Limits reset if the VM restarts, which is
  the right failure mode for login/register throttling.
  """
  use GenServer

  @table __MODULE__
  @sweep_interval_ms :timer.minutes(15)
  @stale_after_ms :timer.hours(1)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @doc """
  Checks a named bucket from application config.

  Returns `:ok` when the limiter is disabled (tests) or the key is under the
  limit, otherwise `{:error, :rate_limited}`.
  """
  def check(bucket, key) when is_atom(bucket) do
    if enabled?() do
      {limit, window_ms} = bucket_limit(bucket)
      hit({bucket, key}, limit, window_ms)
    else
      :ok
    end
  end

  @doc """
  Records one hit for `key`. Returns `:ok` or `{:error, :rate_limited}`.
  """
  def hit(key, limit, window_ms) when is_integer(limit) and limit > 0 and window_ms > 0 do
    now = System.monotonic_time(:millisecond)
    cutoff = now - window_ms

    case :ets.lookup(@table, key) do
      [{^key, count, started}] when started >= cutoff ->
        if count >= limit do
          {:error, :rate_limited}
        else
          :ets.update_counter(@table, key, {2, 1})
          :ok
        end

      _ ->
        :ets.insert(@table, {key, 1, now})
        :ok
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - @stale_after_ms

    :ets.select_delete(@table, [
      {{:"$1", :"$2", :"$3"}, [{:<, :"$3", cutoff}], [true]}
    ])

    schedule_sweep()
    {:noreply, state}
  end

  defp enabled? do
    Application.get_env(:trygg, __MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  defp bucket_limit(bucket) do
    conf = Application.get_env(:trygg, __MODULE__, []) |> Keyword.fetch!(bucket)
    {Keyword.fetch!(conf, :limit), Keyword.fetch!(conf, :window_ms)}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
