defmodule Trygg.StorageTest do
  use ExUnit.Case, async: true

  alias Trygg.Storage

  setup do
    key = "test/#{System.unique_integer([:positive])}/blob.bin"
    on_exit(fn -> Storage.delete(key) end)
    %{key: key}
  end

  test "put then get round-trips the bytes", %{key: key} do
    assert :ok = Storage.put(key, "hello bytes", "application/octet-stream")
    assert {:ok, "hello bytes"} = Storage.get(key)
  end

  test "put overwrites an existing object", %{key: key} do
    :ok = Storage.put(key, "first", "text/plain")
    :ok = Storage.put(key, "second", "text/plain")
    assert {:ok, "second"} = Storage.get(key)
  end

  test "get on a missing key returns an error" do
    assert {:error, _} = Storage.get("test/does-not-exist/#{System.unique_integer()}")
  end

  test "delete is idempotent", %{key: key} do
    :ok = Storage.put(key, "x", "text/plain")
    assert :ok = Storage.delete(key)
    assert :ok = Storage.delete(key)
    assert {:error, _} = Storage.get(key)
  end

  test "the local adapter ignores path-traversal segments in a key" do
    # ".." segments are stripped, so this lands inside the base dir, not above it.
    key = "../../escape/#{System.unique_integer([:positive])}.bin"
    on_exit(fn -> Storage.delete(key) end)

    assert :ok = Storage.put(key, "safe", "text/plain")
    assert {:ok, "safe"} = Storage.get(key)

    base = Trygg.Storage.Local.base_dir()
    assert File.exists?(Path.join(base, "escape/#{Path.basename(key)}"))
  end
end
