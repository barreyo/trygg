defmodule Trygg.Mailer do
  use Swoosh.Mailer, otp_app: :trygg

  @doc """
  The configured sender for outbound mail, as a `{name, address}` tuple ready
  to hand to `Swoosh.Email.from/2`.

  Reads `config :trygg, :email_from`, which is set from the `MAIL_FROM` env var
  in production (see `config/runtime.exs`). Accepts either a bare address
  (`"hello@trygg.app"`) or a named address (`"Trygg <hello@trygg.app>"`).
  """
  @spec from_address() :: {String.t(), String.t()}
  def from_address do
    :trygg
    |> Application.fetch_env!(:email_from)
    |> parse_from()
  end

  defp parse_from({name, address}), do: {to_string(name), to_string(address)}

  defp parse_from(value) when is_binary(value) do
    case Regex.run(~r/^\s*(.*?)\s*<\s*([^>]+?)\s*>\s*$/, value) do
      [_, "", address] -> {"", address}
      [_, name, address] -> {name, address}
      _ -> {"", String.trim(value)}
    end
  end
end
