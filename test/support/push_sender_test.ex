defmodule Trygg.Push.Sender.Test do
  @moduledoc """
  Test `Trygg.Push.Sender`: never touches the network. Records every send as a
  `{:web_push, subscription, message}` message to a listener process and
  returns a canned result.

  In a test:

      setup do
        Trygg.Push.Sender.Test.listen()
        :ok
      end

      test "..." do
        # ... trigger a push ...
        assert_received {:web_push, %{"endpoint" => _}, _message}
      end

  Force a failure to exercise pruning with
  `Trygg.Push.Sender.Test.listen(result: {:error, :expired})`.
  """
  @behaviour Trygg.Push.Sender

  @doc """
  Registers the calling process as the listener and sets the canned result
  (default `{:ok, %{status: 201}}`). Cleared automatically when the test ends.
  """
  def listen(opts \\ []) do
    result = Keyword.get(opts, :result, {:ok, %{status: 201}})
    Application.put_env(:trygg, __MODULE__, pid: self(), result: result)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:trygg, __MODULE__) end)
    :ok
  end

  @impl true
  def deliver(subscription, message) do
    conf = Application.get_env(:trygg, __MODULE__, [])

    case Keyword.get(conf, :pid) do
      pid when is_pid(pid) -> send(pid, {:web_push, subscription, message})
      _ -> :ok
    end

    Keyword.get(conf, :result, {:ok, %{status: 201}})
  end
end
