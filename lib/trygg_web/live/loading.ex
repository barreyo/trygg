defmodule TryggWeb.Loading do
  @moduledoc """
  The one first-load pattern every data screen follows, so pages paint
  instantly and never block on the database before showing *something*:

    * **Static (dead) render** — no queries at all. The page ships its app
      shell (header, tabs) plus a skeleton shaped like the real content, so
      the first paint is fast and nothing is fetched twice (mount runs once
      for the HTTP request and again when the socket connects).
    * **First connected mount** (including live navigation between tabs) —
      the screen's data is fetched in a task via `start_async/3` under the
      `:load` key. The new page swaps in straight away with its skeleton,
      and the LiveView swaps the real content in from `handle_async/3`.
    * **Reconnect** of a page that was already on screen (the phone woke up,
      the network blipped) — fetched inline, so the rejoin render already
      has the content and the screen never flashes back to a skeleton.

  After that first load, realtime refreshes stay synchronous: they're small,
  and a caregiver's own action should show up in the very next render.

  A LiveView using this calls `init/1` in `mount/3`, then `run/3` with a
  zero-arity fetch (capturing plain values, never the socket) and a function
  that applies the result; its `handle_async(:load, …)` clauses call `done/3`.
  Templates branch on `@loaded?` / `@load_failed?`.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [connected?: 1, get_connect_params: 1]

  require Logger

  @doc """
  Sets up the loading assigns. Call from `mount/3` — it reads the connect
  params, which are only available there.
  """
  def init(socket) do
    assign(socket, loaded?: false, load_failed?: false, load_inline?: remount?(socket))
  end

  @doc """
  Loads the screen's data: inline on a reconnect, otherwise in a task under
  `:load` (a no-op on the static render, which keeps its skeleton). Starting
  a new load while one is in flight supersedes it — only the latest result is
  delivered.
  """
  def run(socket, fetch, apply_fun) when is_function(fetch, 0) and is_function(apply_fun, 2) do
    if socket.assigns.load_inline? do
      socket |> apply_fun.(fetch.()) |> loaded()
    else
      socket
      |> assign(load_failed?: false)
      |> Phoenix.LiveView.start_async(:load, fetch)
    end
  end

  @doc """
  Handles the `:load` task's result: applies it, or flags the failure so the
  page can offer a retry instead of a skeleton that never resolves.
  """
  def done(socket, {:ok, data}, apply_fun), do: socket |> apply_fun.(data) |> loaded()

  def done(socket, {:exit, reason}, _apply_fun) do
    Logger.error("#{inspect(socket.view)} failed to load: #{inspect(reason)}")
    assign(socket, load_failed?: true)
  end

  defp loaded(socket), do: assign(socket, loaded?: true, load_failed?: false, load_inline?: false)

  defp remount?(socket) do
    connected?(socket) and
      case get_connect_params(socket) do
        %{"_mounts" => n} when is_integer(n) and n > 0 -> true
        _ -> false
      end
  end
end
