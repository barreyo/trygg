defmodule Trygg.Mailer.Emails do
  @moduledoc """
  The content of every email Trygg sends.

  Each public function takes what the email needs and returns a
  `%{subject:, text:, mjml:}` map: a plain-text body (what text-only clients
  and screen-reader previews see), and the MJML source built from
  `Trygg.Mailer.Components`. `Trygg.Mailer.deliver_content/2` turns that into a
  multipart message; the dev preview page at `/dev/emails` renders the same
  maps.

  Keep the plain-text bodies in step with the HTML ones. The login-code text
  is machine-read in tests (`code is:` followed by the digits), and the link
  appears exactly once so a token can be cut out of it.
  """
  use Phoenix.Component

  import Trygg.Mailer.Components

  # Mirrors `Trygg.Accounts.UserToken`'s magic-link validity.
  @code_minutes 15

  @type content :: %{subject: String.t(), text: String.t(), mjml: String.t()}

  @doc "A login code + magic link for an existing, confirmed user."
  @spec login_code(%{email: String.t(), url: String.t(), code: String.t()}) :: content()
  def login_code(%{email: _, url: _, code: code} = assigns) do
    %{
      subject: "Your Trygg login code is #{code}",
      text: """
      Welcome back to Trygg!

      Your login code is:

      #{code}

      Enter it in the Trygg app, or log in directly by visiting the link below:

      #{assigns.url}

      The code and link expire in #{@code_minutes} minutes and can only be used once.

      If you didn't ask for this, you can safely ignore this email. Nobody can
      get in without the code.
      """,
      mjml: render(&login_code_mjml/1, assigns)
    }
  end

  defp login_code_mjml(assigns) do
    ~H"""
    <.layout
      title="Your Trygg login code"
      preheader={"Your code is #{@code}. It works for #{code_minutes()} minutes."}
      hero={:mail}
      hero_alt="A letter with a heart on it"
      reason={"You're getting this because someone asked to log in to Trygg as #{@email}."}
    >
      <.heading>Welcome back! 👋</.heading>
      <.copy>
        Here's your one-time code. Type it into the Trygg app, or tap the button to jump straight in.
      </.copy>
      <.code_box code={@code} caption={"Expires in #{code_minutes()} minutes · works once"} />
      <.button href={@url}>Log in to Trygg</.button>
      <.link_fallback href={@url} />
      <.fine_print>
        Didn't ask for this? No worries, just ignore this email. Nobody can get in without the code.
      </.fine_print>
    </.layout>
    """
  end

  @doc "The same code + link, for someone confirming a brand-new account."
  @spec confirm_account(%{email: String.t(), url: String.t(), code: String.t()}) :: content()
  def confirm_account(%{email: _, url: _, code: code} = assigns) do
    %{
      subject: "Confirm your Trygg account — code #{code}",
      text: """
      Welcome to Trygg!

      One tiny step: confirm it's really you. Your confirmation code is:

      #{code}

      Enter it in the Trygg app, or confirm your account by visiting the link below:

      #{assigns.url}

      The code and link expire in #{@code_minutes} minutes and can only be used once.

      What's next:
      - Add your little one
      - Log feeds, sleep and diapers in a couple of taps
      - Invite a co-parent or caregiver to follow along in real time

      If you didn't create an account with us, you can ignore this email.
      """,
      mjml: render(&confirm_account_mjml/1, assigns)
    }
  end

  defp confirm_account_mjml(assigns) do
    ~H"""
    <.layout
      title="Confirm your Trygg account"
      preheader={"Your confirmation code is #{@code}. Welcome to Trygg!"}
      hero={:cradle}
      hero_alt="A baby fast asleep in a cradle on a cloud"
      reason={"You're getting this because #{@email} was used to create a Trygg account."}
    >
      <.heading>Welcome to Trygg! 🎉</.heading>
      <.copy>
        One tiny step and you're in: confirm it's really you with this code, or tap the button.
      </.copy>
      <.code_box code={@code} caption={"Expires in #{code_minutes()} minutes · works once"} />
      <.button href={@url}>Confirm my account</.button>
      <.link_fallback href={@url} />
      <.steps>
        <:item icon="👶">Add your little one</:item>
        <:item icon="🍼">Log feeds, sleep and diapers in a couple of taps</:item>
        <:item icon="💛">Invite a co-parent or caregiver to follow along in real time</:item>
      </.steps>
      <.fine_print>
        Didn't create an account? Just ignore this email and we'll forget about it.
      </.fine_print>
    </.layout>
    """
  end

  @doc "Confirmation link for changing the address on an account."
  @spec update_email(%{email: String.t(), url: String.t()}) :: content()
  def update_email(%{email: _, url: _} = assigns) do
    %{
      subject: "Confirm your new email for Trygg",
      text: """
      Hi,

      Someone asked to change the email on your Trygg account to this address.
      To confirm the change, visit the link below:

      #{assigns.url}

      If you didn't request this change, you can ignore this email and nothing
      will happen.
      """,
      mjml: render(&update_email_mjml/1, assigns)
    }
  end

  defp update_email_mjml(assigns) do
    ~H"""
    <.layout
      title="Confirm your new email"
      preheader="Tap to confirm the new email address for your Trygg account."
      hero={:mail}
      hero_alt="A letter with a heart on it"
      reason={"You're getting this because #{@email} was entered as a new email address on a Trygg account."}
    >
      <.heading>Change your email?</.heading>
      <.copy>
        Someone asked to switch the email on a Trygg account to this address. If that was you, confirm it below and you're all set.
      </.copy>
      <.button href={@url}>Confirm new email</.button>
      <.link_fallback href={@url} />
      <.fine_print>
        Didn't request this? Ignore this email and nothing will change.
      </.fine_print>
    </.layout>
    """
  end

  @doc """
  An invitation to follow a family's children. `invite` is a
  `Trygg.Families.Invite`, `invited_by` the inviting `Trygg.Accounts.User`.
  """
  @spec caregiver_invite(%{
          invite: struct(),
          family_label: String.t(),
          invited_by: struct(),
          url: String.t()
        }) :: content()
  def caregiver_invite(%{invite: invite, family_label: label, invited_by: inviter} = assigns) do
    assigns =
      Map.merge(assigns, %{role_blurb: role_blurb(invite.role), expires: expires_on(invite)})

    %{
      subject: "You're invited to help track #{label} on Trygg",
      text: """
      Hi,

      #{inviter.email} invited you to help track #{label} on Trygg as a #{invite.role}: #{assigns.role_blurb}.

      Accept the invitation by visiting the link below. You'll be asked to log in
      or create an account with this email address first.

      #{assigns.url}

      This invite expires on #{assigns.expires}.

      If you weren't expecting this, you can ignore this email.
      """,
      mjml: render(&caregiver_invite_mjml/1, assigns)
    }
  end

  defp caregiver_invite_mjml(assigns) do
    ~H"""
    <.layout
      title="You're invited to Trygg"
      preheader={"#{@invited_by.email} wants you to help look after #{@family_label}."}
      hero={:cradle}
      hero_alt="A baby fast asleep in a cradle on a cloud"
      reason={"You're getting this because #{@invited_by.email} invited #{@invite.email} to Trygg."}
    >
      <.heading>Join the little crew 💛</.heading>
      <.copy>
        <strong>{@invited_by.email}</strong>
        invited you to help track <strong>{@family_label}</strong>
        on Trygg, so everyone caring for them sees the same feeds, naps and diapers in real time.
      </.copy>
      <.button href={@url}>Accept invitation</.button>
      <.callout icon="🔑">
        You'll join as a <strong>{@invite.role}</strong>: {@role_blurb}.
      </.callout>
      <.callout icon="✉️">
        You'll be asked to log in or create an account with <strong>{@invite.email}</strong> first.
      </.callout>
      <.callout icon="⏳">This invite expires on <strong>{@expires}</strong>.</.callout>
      <.link_fallback href={@url} />
      <.fine_print>
        Weren't expecting this? You can safely ignore this email.
      </.fine_print>
    </.layout>
    """
  end

  @doc """
  Nudges a caregiver that a child's routine weight check is overdue. `status`
  is a `Trygg.Growth.CheckReminder` map.
  """
  @spec weight_reminder(%{
          child: struct(),
          status: map(),
          url: String.t(),
          preferences_url: String.t()
        }) :: content()
  def weight_reminder(%{child: child, status: status} = assigns) do
    assigns =
      Map.put(assigns, :last_on, status.last_measured_on && format_date(status.last_measured_on))

    history =
      if status.last_measured_on do
        "The last weight for #{child.name} was logged on #{assigns.last_on}, #{status.days_since} days ago."
      else
        "No weight has been logged for #{child.name} yet."
      end

    %{
      subject: "Time to check #{child.name}'s weight",
      text: """
      Hi,

      #{history}

      The CDC's well-child schedule suggests a weight check about every
      #{status.interval_days} days at #{child.name}'s age. Next time you have a
      chance, add the latest weight here:

      #{assigns.url}

      Want these less (or more) often? Change it in your preferences:

      #{assigns.preferences_url}

      This is a routine reminder, not medical advice. Talk to your pediatrician
      if you have any concerns.
      """,
      mjml: render(&weight_reminder_mjml/1, assigns)
    }
  end

  defp weight_reminder_mjml(assigns) do
    ~H"""
    <.layout
      title={"Time to weigh #{@child.name}"}
      preheader={"A quick weigh-in is due for #{@child.name}. It takes a minute."}
      hero={:scale}
      hero_alt="A smiling baby scale"
      reason="You're getting this because you're a caregiver on Trygg with weight reminders switched on."
    >
      <.heading>⚖️ Weigh-in time for {@child.name}</.heading>
      <.copy>
        <%= if @status.last_measured_on do %>
          It's been a little while since the last weight was logged. Whenever you have a spare minute, add the latest one so the growth chart stays up to date.
        <% else %>
          No weight has been logged for {@child.name} yet. Add the first one and the growth chart can start filling in.
        <% end %>
      </.copy>
      <.stats>
        <:tile
          :if={@status.last_measured_on}
          value={"#{@status.days_since} days"}
          label={"since the last weigh-in (#{@last_on})"}
        />
        <:tile :if={!@status.last_measured_on} value="Not yet" label="no weight logged so far" />
        <:tile value={"~#{@status.interval_days} days"} label="suggested between checks" />
      </.stats>
      <.button href={@url}>Add {@child.name}'s weight</.button>
      <.fine_print>
        The suggested spacing follows the CDC's well-child schedule for {@child.name}'s age.
        <a href={@preferences_url}>Change how often you're reminded</a>
        or switch these off any time. <br /><br />
        This is a routine reminder, not medical advice. Talk to your pediatrician if you have any concerns.
      </.fine_print>
    </.layout>
    """
  end

  # -- helpers ----------------------------------------------------------------

  # Function components return `%Phoenix.LiveView.Rendered{}`; MJML wants the
  # plain string.
  defp render(component, assigns) do
    assigns
    |> component.()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp code_minutes, do: @code_minutes

  defp format_date(date), do: Calendar.strftime(date, "%b %-d, %Y")

  defp expires_on(%{expires_at: expires_at}), do: format_date(expires_at)

  defp role_blurb(:caregiver), do: "you can log feeds, sleep and diapers"
  defp role_blurb(:viewer), do: "you can follow along, but not add entries"
  defp role_blurb(_), do: "you'll be able to follow along"
end
