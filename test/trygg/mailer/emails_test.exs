defmodule Trygg.Mailer.EmailsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Trygg.Accounts.User
  alias Trygg.Families.Child
  alias Trygg.Families.Invite
  alias Trygg.Mailer
  alias Trygg.Mailer.Emails

  @url "https://trygg.test/go/abc123"

  defp build(content), do: Mailer.build("you@example.com", content)

  defp invite_assigns(overrides \\ %{}) do
    Map.merge(
      %{
        invite: %Invite{
          email: "alex@example.com",
          role: :caregiver,
          expires_at: ~U[2026-10-15 12:00:00Z]
        },
        family_label: "Alma & Otto",
        invited_by: %User{email: "sam@example.com"},
        url: @url
      },
      overrides
    )
  end

  defp reminder_assigns(status) do
    %{
      child: %Child{name: "Alma"},
      status: status,
      url: @url,
      preferences_url: "https://trygg.test/preferences"
    }
  end

  describe "every email" do
    test "compiles to complete HTML alongside a plain-text body" do
      contents = [
        Emails.login_code(%{email: "sam@example.com", url: @url, code: "482917"}),
        Emails.confirm_account(%{email: "sam@example.com", url: @url, code: "482917"}),
        Emails.update_email(%{email: "sam@example.com", url: @url}),
        Emails.caregiver_invite(invite_assigns()),
        Emails.weight_reminder(
          reminder_assigns(%{last_measured_on: ~D[2026-09-20], days_since: 18, interval_days: 14})
        ),
        Emails.weight_reminder(
          reminder_assigns(%{last_measured_on: nil, days_since: 30, interval_days: 14})
        )
      ]

      for content <- contents do
        email = build(content)

        assert email.text_body =~ @url
        assert email.html_body =~ "<!doctype html>"
        # The button points where the plain-text link does…
        assert email.html_body =~ ~s(href="#{@url}")
        # …and the banner is an absolute URL, which mail clients require.
        assert email.html_body =~ ~r{src="https?://[^"]+/images/email/hero-[a-z]+\.png"}
        # No MJML tag leaked through uncompiled.
        refute email.html_body =~ "<mj-"
      end
    end

    test "banner images are shipped in priv/static" do
      for hero <- ~w(mail cradle scale) do
        assert File.exists?(
                 Application.app_dir(:trygg, "priv/static/images/email/hero-#{hero}.png")
               )
      end
    end
  end

  describe "login and confirmation codes" do
    test "the code appears in the subject, preview line, HTML and text" do
      content = Emails.login_code(%{email: "sam@example.com", url: @url, code: "482917"})
      email = build(content)

      assert email.subject == "Your Trygg login code is 482917"
      assert email.html_body =~ "482917"
      # Tests (and the app) read the code out of the plain-text body.
      assert [_, "482917"] = Regex.run(~r/code is:\s+(\d{6})/, email.text_body)
    end

    test "a new account gets a confirmation email, not a login one" do
      content = Emails.confirm_account(%{email: "sam@example.com", url: @url, code: "482917"})

      assert content.subject =~ "Confirm your Trygg account"
      assert content.text =~ "confirmation code is:"
    end
  end

  describe "caregiver invites" do
    test "describes what the role can do and when the invite expires" do
      email = build(Emails.caregiver_invite(invite_assigns()))

      assert email.subject == "You're invited to help track Alma & Otto on Trygg"
      assert email.text_body =~ "This invite expires on Oct 15, 2026."
      assert email.text_body =~ "you can log feeds"

      viewer =
        Emails.caregiver_invite(
          invite_assigns(%{
            invite: %Invite{
              email: "v@example.com",
              role: :viewer,
              expires_at: ~U[2026-10-15 12:00:00Z]
            }
          })
        )

      assert viewer.text =~ "but not add entries"
    end

    test "escapes names and addresses in the HTML" do
      email =
        build(
          Emails.caregiver_invite(
            invite_assigns(%{
              family_label: "<script>alert(1)</script> & co",
              invited_by: %User{email: "o'brien@example.com"}
            })
          )
        )

      refute email.html_body =~ "<script>alert(1)</script>"
      assert email.html_body =~ "&lt;script&gt;"
    end
  end

  describe "weight reminders" do
    test "says how long it has been and links to the preferences" do
      email =
        build(
          Emails.weight_reminder(
            reminder_assigns(%{
              last_measured_on: ~D[2026-09-20],
              days_since: 18,
              interval_days: 14
            })
          )
        )

      assert email.subject == "Time to check Alma's weight"
      assert email.text_body =~ "logged on Sep 20, 2026, 18 days ago"
      assert email.text_body =~ "https://trygg.test/preferences"
      assert email.html_body =~ "18 days"
      assert email.html_body =~ ~s(href="https://trygg.test/preferences")
    end

    test "handles a child who has never been weighed" do
      email =
        build(
          Emails.weight_reminder(
            reminder_assigns(%{last_measured_on: nil, days_since: 30, interval_days: 14})
          )
        )

      assert email.text_body =~ "No weight has been logged for Alma yet."
      assert email.html_body =~ "Not yet"
    end
  end

  describe "Mailer.build/2" do
    test "falls back to plain text when the MJML does not compile" do
      log =
        capture_log(fn ->
          email = build(%{subject: "Hi", text: "plain", mjml: "this is not mjml"})

          assert email.text_body == "plain"
          assert email.html_body == nil
        end)

      assert log =~ "MJML render failed"
    end
  end
end
