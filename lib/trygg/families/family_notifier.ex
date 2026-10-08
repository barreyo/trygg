defmodule Trygg.Families.FamilyNotifier do
  @moduledoc false

  alias Trygg.Mailer
  alias Trygg.Mailer.Emails

  @doc """
  Delivers a caregiver invitation to join a family. `family_label` names the
  children in it (see `Trygg.Families.Family.label/1`).
  """
  def deliver_caregiver_invite(invite, family_label, invited_by, url) do
    Mailer.deliver_content(
      invite.email,
      Emails.caregiver_invite(%{
        invite: invite,
        family_label: family_label,
        invited_by: invited_by,
        url: url
      })
    )
  end

  @doc """
  Nudges a caregiver that a child's routine weight check is overdue. `status`
  is a `Trygg.Growth.CheckReminder` map.
  """
  def deliver_weight_check_reminder(recipient, child, status, url) do
    Mailer.deliver_content(
      recipient,
      Emails.weight_reminder(%{
        child: child,
        status: status,
        url: url,
        preferences_url: TryggWeb.Endpoint.url() <> "/preferences"
      })
    )
  end
end
