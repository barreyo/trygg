defmodule TryggWeb.EmailPreviewController do
  @moduledoc """
  Dev-only gallery of every email Trygg sends, rendered with sample data
  (mounted at `/dev/emails`, see the router). Faster than triggering each flow
  by hand and checking `/dev/mailbox`: edit a template, refresh, look.

  `?format=text` shows the plain-text alternative instead of the HTML.
  """
  use TryggWeb, :controller

  alias Trygg.Mailer
  alias Trygg.Mailer.Emails

  @previews [
    {"login-code", "Login code (existing user)"},
    {"confirm-account", "Confirm account (new user)"},
    {"update-email", "Change email"},
    {"caregiver-invite", "Caregiver invite"},
    {"weight-reminder", "Weight check reminder"},
    {"weight-reminder-first", "Weight check reminder (first weigh-in)"}
  ]

  def index(conn, _params) do
    items =
      for {name, title} <- @previews do
        ~s(<li><strong>#{Plug.HTML.html_escape(title)}</strong> · ) <>
          ~s(<a href="/dev/emails/#{name}">HTML</a> · ) <>
          ~s(<a href="/dev/emails/#{name}?format=text">plain text</a></li>)
      end

    send_html(conn, """
    <!doctype html>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Email previews</title>
    <body style="font-family: ui-rounded, system-ui, sans-serif; max-width: 36rem; margin: 3rem auto; padding: 0 1rem; line-height: 2">
    <h1>Email previews</h1>
    <ul>#{items}</ul>
    </body>
    """)
  end

  def show(conn, %{"name" => name} = params) do
    case sample(name) do
      nil ->
        send_resp(conn, 404, "No such email")

      content ->
        case params["format"] do
          "text" -> text(conn, content.text)
          _ -> send_html(conn, Mailer.build("you@example.com", content).html_body || content.text)
        end
    end
  end

  # Both pages are built from this module's static samples, never from request
  # input, so plain `send_resp` is fine here.
  # sobelow_skip ["XSS.SendResp"]
  defp send_html(conn, body) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, body)
  end

  defp sample("login-code"),
    do:
      Emails.login_code(%{
        email: "sam@example.com",
        url: sample_url("/users/log-in/abc123"),
        code: "482917"
      })

  defp sample("confirm-account"),
    do:
      Emails.confirm_account(%{
        email: "sam@example.com",
        url: sample_url("/users/log-in/abc123"),
        code: "482917"
      })

  defp sample("update-email"),
    do:
      Emails.update_email(%{
        email: "sam@example.com",
        url: sample_url("/users/settings/confirm-email/abc123")
      })

  defp sample("caregiver-invite") do
    Emails.caregiver_invite(%{
      invite: %Trygg.Families.Invite{
        email: "alex@example.com",
        role: :caregiver,
        expires_at: DateTime.add(DateTime.utc_now(), 7, :day)
      },
      family_label: "Alma & Otto",
      invited_by: %Trygg.Accounts.User{email: "sam@example.com"},
      url: sample_url("/invites/abc123")
    })
  end

  defp sample("weight-reminder") do
    weight_reminder(%{
      last_measured_on: Date.add(Date.utc_today(), -16),
      days_since: 16,
      interval_days: 14
    })
  end

  defp sample("weight-reminder-first") do
    weight_reminder(%{last_measured_on: nil, days_since: 21, interval_days: 14})
  end

  defp sample(_), do: nil

  defp weight_reminder(status) do
    Emails.weight_reminder(%{
      child: %Trygg.Families.Child{name: "Alma"},
      status: status,
      url: sample_url("/c/1/vitals"),
      preferences_url: sample_url("/preferences")
    })
  end

  defp sample_url(path), do: TryggWeb.Endpoint.url() <> path
end
