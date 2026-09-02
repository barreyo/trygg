defmodule Trygg.RateLimitTest do
  use ExUnit.Case, async: true

  alias Trygg.RateLimit

  test "allows up to the limit inside the window, then rejects" do
    key = {:test, System.unique_integer([:positive])}

    assert :ok = RateLimit.hit(key, 2, 60_000)
    assert :ok = RateLimit.hit(key, 2, 60_000)
    assert {:error, :rate_limited} = RateLimit.hit(key, 2, 60_000)
  end

  test "resets after the window elapses" do
    key = {:test, System.unique_integer([:positive])}

    assert :ok = RateLimit.hit(key, 1, 20)
    assert {:error, :rate_limited} = RateLimit.hit(key, 1, 20)
    Process.sleep(25)
    assert :ok = RateLimit.hit(key, 1, 20)
  end

  test "check/2 is a no-op when the limiter is disabled" do
    assert :ok = RateLimit.check(:login_ip, "disabled-#{System.unique_integer([:positive])}")
  end
end
