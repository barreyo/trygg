defmodule Trygg.Families.FamilyNotifier do
  @moduledoc false
  import Swoosh.Email

  alias Trygg.Mailer

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(Mailer.from_address())
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

  @doc """
  Nudges a caregiver that a child's routine weight check is overdue. `status`
  is a `Trygg.Growth.CheckReminder` map.
  """
  def deliver_weight_check_reminder(recipient, child, status, url) do
    history =
      if status.last_measured_on do
        "The last weight for #{child.name} was logged on " <>
          "#{Calendar.strftime(status.last_measured_on, "%Y-%m-%d")}, #{status.days_since} days ago."
      else
        "No weight has been logged for #{child.name} yet."
      end

    deliver(recipient, "Time to check #{child.name}'s weight", """

    ==============================

    Hi,

    #{history}

    The CDC's well-child schedule suggests a weight check about every
    #{status.interval_days} days at #{child.name}'s age. Next time you have a
    chance, add the latest weight here:

    #{url}

    This is a routine reminder, not medical advice — talk to your pediatrician
    if you have any concerns.

    ==============================
    """)
  end
end
