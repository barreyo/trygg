defmodule Trygg.Families.FamilyNotifier do
  @moduledoc false
  import Swoosh.Email

  alias Trygg.Mailer

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"Trygg", "contact@example.com"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Delivers a caregiver invitation to join a child's log.
  """
  def deliver_caregiver_invite(invite, child, invited_by, url) do
    deliver(invite.email, "You're invited to help track #{child.name} on Trygg", """

    ==============================

    Hi,

    #{invited_by.email} invited you to help track #{child.name} on Trygg
    as a #{invite.role}.

    Accept the invitation by visiting the URL below. You'll be asked to
    log in or create an account with this email address first.

    #{url}

    This invite expires on #{Calendar.strftime(invite.expires_at, "%Y-%m-%d")}.

    If you weren't expecting this, you can ignore this email.

    ==============================
    """)
  end
end
