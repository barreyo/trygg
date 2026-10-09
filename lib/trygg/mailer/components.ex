defmodule Trygg.Mailer.Components do
  @moduledoc """
  The building blocks every Trygg email is made of, written as HEEx function
  components that emit [MJML](https://mjml.io). `Trygg.Mailer.Emails` composes
  them into the actual messages and `Trygg.Mailer` compiles the result to
  client-safe HTML with `Mjml.to_html/2`.

  The look mirrors the app's login screen: a night-sky banner with the same
  little characters, a warm cream card, chunky orange "sticker" buttons and
  rounded type. Mail clients can't do gradients or SVG reliably, so the sky and
  characters are pre-rendered PNG banners (`priv/static/images/email/`, source
  in `assets/email-art/`) and everything else is flat color.

  Dark mode is a progressive enhancement: clients that honour
  `prefers-color-scheme` flip the card to deep indigo, everything else keeps the
  light card. Every color the dark rules override carries a CSS class
  (`.card`, `.ink`, `.muted`, `.well`) for that reason.

  Text is escaped by HEEx, so user-supplied names and emails are safe to
  interpolate anywhere in these templates.
  """
  use Phoenix.Component

  alias Trygg.Mailer

  # Palette, lifted from the login screen.
  @night "#1b1450"
  @cream "#fffdf8"
  @ink "#2b2350"
  @muted "#6f6590"
  @sticker "#ffa24c"
  @sticker_edge "#d97a1f"
  @sticker_ink "#2b1500"

  @font ~s(ui-rounded, "SF Pro Rounded", -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif)
  @mono ~s(ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace)

  @css """
  :root { color-scheme: light dark; supported-color-schemes: light dark; }
  .ink a, .muted a { color: #d9560b; }
  @media (prefers-color-scheme: dark) {
    body, .page { background-color: #0e0a2e !important; }
    .card, .card > table { background-color: #251c66 !important; }
    .ink, .ink * { color: #f4f0ff !important; }
    .muted, .muted * { color: #b9aee6 !important; }
    .well > table > tbody > tr > td { background-color: #33297f !important; border-color: #6a58c4 !important; }
    .ink a, .muted a { color: #ffb468 !important; }
  }
  """

  @heroes %{
    mail: "/images/email/hero-mail.png",
    cradle: "/images/email/hero-cradle.png",
    scale: "/images/email/hero-scale.png"
  }

  @doc """
  The whole email: head, banner, card and footer. Everything in the inner block
  goes inside the card, so it should be made of the components below.
  """
  attr :title, :string, required: true, doc: "The document title (shown in some clients' tabs)."
  attr :preheader, :string, required: true, doc: "The grey preview line next to the subject."
  attr :hero, :atom, values: [:mail, :cradle, :scale], required: true
  attr :hero_alt, :string, required: true
  attr :reason, :string, required: true, doc: "Why they're getting this, for the footer."
  slot :inner_block, required: true

  # `@css` is a compile-time constant stylesheet, never user input.
  # sobelow_skip ["XSS.Raw"]
  def layout(assigns) do
    assigns =
      assign(assigns,
        hero_src: Mailer.asset_url(Map.fetch!(@heroes, assigns.hero)),
        css: @css,
        night: @night,
        cream: @cream,
        font: @font
      )

    ~H"""
    <mjml lang="en">
      <mj-head>
        <mj-title>{@title}</mj-title>
        <mj-preview>{@preheader}</mj-preview>
        <mj-attributes>
          <mj-all font-family={@font} />
          <mj-text font-size="16px" line-height="1.55" color={ink()} padding="0" />
          <mj-section padding="0" />
          <mj-column padding="0" />
        </mj-attributes>
        <mj-style>{Phoenix.HTML.raw(@css)}</mj-style>
      </mj-head>
      <mj-body background-color={@night} css-class="page" width="600px">
        <mj-wrapper padding="28px 0 0">
          <mj-section>
            <mj-column>
              <mj-text
                align="center"
                font-size="24px"
                font-weight="800"
                letter-spacing="1px"
                color="#fff3c4"
                padding="0 0 14px"
              >
                Trygg <span style="color:#ff7fa3">♥</span>
              </mj-text>
            </mj-column>
          </mj-section>
          <mj-section background-color={@night} border-radius="26px 26px 0 0" css-class="banner">
            <mj-column>
              <mj-image
                src={@hero_src}
                alt={@hero_alt}
                width="600px"
                padding="0"
                border-radius="26px 26px 0 0"
              />
            </mj-column>
          </mj-section>
        </mj-wrapper>
        <mj-wrapper
          background-color={@cream}
          css-class="card"
          border-radius="0 0 26px 26px"
          padding="28px 28px 30px"
        >
          {render_slot(@inner_block)}
        </mj-wrapper>
        <mj-wrapper padding="18px 24px 34px">
          <mj-section>
            <mj-column>
              <mj-text align="center" font-size="12px" line-height="1.6" color="#b9aee6">
                {@reason}
                <br /> Sent with <span style="color:#ff7fa3">♥</span> from Trygg
              </mj-text>
            </mj-column>
          </mj-section>
        </mj-wrapper>
      </mj-body>
    </mjml>
    """
  end

  @doc "The big friendly headline."
  slot :inner_block, required: true

  def heading(assigns) do
    ~H"""
    <mj-section>
      <mj-column>
        <mj-text
          css-class="ink"
          font-size="28px"
          font-weight="800"
          line-height="1.2"
          padding="0 0 12px"
        >
          {render_slot(@inner_block)}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @doc "A paragraph of body copy. `tone` softens secondary paragraphs."
  attr :tone, :atom, values: [:normal, :muted], default: :normal
  slot :inner_block, required: true

  def copy(assigns) do
    assigns = assign(assigns, ink: ink(), muted: @muted)

    ~H"""
    <mj-section>
      <mj-column>
        <mj-text
          css-class={if @tone == :muted, do: "muted", else: "ink"}
          color={if @tone == :muted, do: @muted, else: @ink}
          font-size={if @tone == :muted, do: "14px", else: "16px"}
          padding="0 0 16px"
        >
          {render_slot(@inner_block)}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  The one-time code, big and tappable-looking. Spaced with CSS letter-spacing
  rather than real spaces so copying it gives the bare digits.
  """
  attr :code, :string, required: true
  attr :caption, :string, required: true

  def code_box(assigns) do
    assigns = assign(assigns, mono: @mono, ink: ink(), muted: @muted)

    ~H"""
    <mj-section padding="4px 0 22px">
      <mj-column
        css-class="well"
        background-color="#fff1dc"
        border="2px dashed #f0b987"
        border-radius="22px"
      >
        <mj-text
          align="center"
          css-class="ink"
          font-family={@mono}
          font-size="40px"
          font-weight="800"
          letter-spacing="10px"
          color={@ink}
          padding="22px 0 4px 10px"
        >
          {@code}
        </mj-text>
        <mj-text
          align="center"
          css-class="muted"
          font-size="13px"
          color="#8a6a45"
          padding="0 12px 18px"
        >
          {@caption}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @doc "The primary call to action: a chunky orange sticker button."
  attr :href, :string, required: true
  slot :inner_block, required: true

  def button(assigns) do
    assigns = assign(assigns, sticker: @sticker, edge: @sticker_edge, ink: @sticker_ink)

    ~H"""
    <mj-section padding="2px 0 6px">
      <mj-column>
        <mj-button
          href={@href}
          background-color={@sticker}
          color={@ink}
          font-size="18px"
          font-weight="800"
          border-radius="999px"
          border-bottom={"4px solid #{@edge}"}
          inner-padding="16px 44px"
          padding="0"
        >
          {render_slot(@inner_block)}
        </mj-button>
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  The link spelled out, for clients that block buttons or people copying it to
  another device.
  """
  attr :href, :string, required: true

  def link_fallback(assigns) do
    assigns = assign(assigns, muted: @muted)

    ~H"""
    <mj-section padding="14px 0 0">
      <mj-column>
        <mj-text css-class="muted" font-size="12px" line-height="1.5" color={@muted}>
          Button not working? Paste this link into your browser:<br />
          <a href={@href} style="word-break:break-all">{@href}</a>
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @doc "A soft, rounded aside — expiry notes, reassurance, who-can-do-what."
  attr :icon, :string, required: true
  slot :inner_block, required: true

  def callout(assigns) do
    assigns = assign(assigns, ink: ink())

    ~H"""
    <mj-section padding="10px 0 0">
      <mj-column
        css-class="well"
        background-color="#f4efff"
        border="2px solid #e1d8fb"
        border-radius="18px"
      >
        <mj-text css-class="ink" font-size="14px" line-height="1.5" color={@ink} padding="12px 16px">
          <span style="font-size:18px;vertical-align:middle;margin-right:6px">{@icon}</span>
          {render_slot(@inner_block)}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @doc "A row of big-number tiles (two or three)."
  slot :tile, required: true do
    attr :value, :string, required: true
    attr :label, :string, required: true
  end

  def stats(assigns) do
    assigns = assign(assigns, ink: ink(), muted: @muted)

    ~H"""
    <mj-section padding="2px 0 18px">
      <mj-column
        :for={tile <- @tile}
        css-class="well"
        background-color="#fff1dc"
        border="2px solid #f6dcb8"
        border-radius="18px"
        padding="5px"
      >
        <mj-text
          align="center"
          css-class="ink"
          font-size="26px"
          font-weight="800"
          color={@ink}
          padding="14px 8px 0"
        >
          {tile.value}
        </mj-text>
        <mj-text
          align="center"
          css-class="muted"
          font-size="13px"
          color="#8a6a45"
          padding="2px 8px 14px"
        >
          {tile.label}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @doc "A short checklist with an emoji bullet per line."
  slot :item, required: true do
    attr :icon, :string, required: true
  end

  def steps(assigns) do
    assigns = assign(assigns, ink: ink())

    ~H"""
    <mj-section padding="22px 0 0">
      <mj-column>
        <mj-text
          css-class="ink"
          font-size="13px"
          font-weight="800"
          letter-spacing="1px"
          color={@ink}
          padding="0 0 6px"
        >
          WHAT'S NEXT
        </mj-text>
      </mj-column>
    </mj-section>
    <%!-- An mj-group keeps icon and text side by side on phones, where bare
         columns would stack. --%>
    <mj-section :for={item <- @item} padding="0">
      <mj-group>
        <mj-column width="12%" vertical-align="middle">
          <mj-text align="center" font-size="22px" padding="6px 0">{item.icon}</mj-text>
        </mj-column>
        <mj-column width="88%" vertical-align="middle">
          <mj-text css-class="ink" font-size="15px" line-height="1.45" color={@ink} padding="6px 0">
            {render_slot(item)}
          </mj-text>
        </mj-column>
      </mj-group>
    </mj-section>
    """
  end

  @doc "The small print at the bottom of the card."
  slot :inner_block, required: true

  def fine_print(assigns) do
    assigns = assign(assigns, muted: @muted)

    ~H"""
    <mj-section padding="22px 0 0">
      <mj-column>
        <mj-divider
          border-width="2px"
          border-style="dotted"
          border-color="#e1d8fb"
          padding="0 0 14px"
        />
        <mj-text css-class="muted" font-size="13px" line-height="1.55" color={@muted}>
          {render_slot(@inner_block)}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  defp ink, do: @ink
end
