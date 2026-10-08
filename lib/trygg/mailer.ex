defmodule Trygg.Mailer do
  use Swoosh.Mailer, otp_app: :trygg

  import Swoosh.Email

  require Logger

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

  @doc """
  An absolute URL for a static file. Mail clients can't resolve relative
  paths, so the images in an email have to point at the public host.
  """
  @spec asset_url(String.t()) :: String.t()
  def asset_url("/" <> _ = path), do: TryggWeb.Endpoint.url() <> path

  @doc """
  Builds a multipart email from one of the `Trygg.Mailer.Emails` content maps:
  the MJML-rendered HTML plus the plain-text fallback.

  If the MJML fails to compile the email still goes out as plain text — a
  login code that never arrives is far worse than an unstyled one.
  """
  @spec build(String.t(), %{subject: String.t(), text: String.t(), mjml: String.t()}) ::
          Swoosh.Email.t()
  def build(recipient, %{subject: subject, text: text, mjml: mjml}) do
    email =
      new()
      |> to(recipient)
      |> from(from_address())
      |> subject(subject)
      |> text_body(text)

    case Mjml.to_html(mjml, keep_comments: false) do
      {:ok, html} ->
        html_body(email, html)

      {:error, reason} ->
        Logger.error("MJML render failed for #{inspect(subject)}: #{inspect(reason)}")
        email
    end
  end

  @doc """
  Builds and delivers a content map from `Trygg.Mailer.Emails`. Returns
  `{:ok, email}` so callers (and tests) can inspect what went out.
  """
  @spec deliver_content(String.t(), map()) :: {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_content(recipient, content) do
    email = build(recipient, content)

    with {:ok, _metadata} <- deliver(email) do
      {:ok, email}
    end
  end
end
