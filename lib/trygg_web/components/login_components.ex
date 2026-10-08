defmodule TryggWeb.LoginComponents do
  @moduledoc """
  Illustrations for the signed-out login / registration screens.

  The scene is inline SVG animated purely with CSS (`.login-*` rules in
  app.css), so it costs no extra requests and every motion switches off under
  `prefers-reduced-motion`. It paints its own dusk-to-night sky, so the colors
  are fixed rather than theme tokens: the same window looks right on the warm
  light theme and on the true-black dark one.

  The one bit of JS is the `LoginScene` hook, which only restarts a CSS
  animation when the scene is tapped.
  """
  use Phoenix.Component

  # Stars as {x, y, scale, delay-seconds, color}.
  @stars [
    {34, 26, 1.0, 0.0, "#fff3c4"},
    {84, 14, 0.7, 0.8, "#ffffff"},
    {118, 40, 0.9, 1.6, "#ffe29a"},
    {196, 24, 0.8, 0.4, "#ffffff"},
    {24, 78, 0.7, 2.0, "#ffffff"},
    {62, 54, 0.6, 1.0, "#fff3c4"},
    {296, 92, 0.8, 1.2, "#fff3c4"}
  ]

  # Pin-prick stars as {x, y, delay-seconds}.
  @dots [
    {150, 20, 0.3},
    {176, 54, 1.4},
    {98, 72, 0.9},
    {300, 20, 2.2},
    {12, 40, 1.8},
    {236, 12, 0.5},
    {274, 112, 2.6},
    {44, 112, 1.1}
  ]

  @doc """
  The animated sky-window shown above the login form.

  `variant` picks the scene: `:night` (a baby asleep in a rocking cradle) for
  the email step, `:mail` (an envelope with a code typing itself in) for the
  "check your email" step. Tapping the scene pops a few hearts.
  """
  attr :variant, :atom, values: [:night, :mail], default: :night

  def login_scene(assigns) do
    assigns = assign(assigns, stars: @stars, dots: @dots)

    ~H"""
    <div
      id={"login-scene-#{@variant}"}
      phx-hook="LoginScene"
      phx-update="ignore"
      aria-hidden="true"
      class="login-scene login-scene-in mx-auto aspect-[16/9] w-[min(100%,calc(32dvh*16/9))] cursor-pointer overflow-hidden rounded-3xl border border-white/10 shadow-lg shadow-black/25 select-none"
    >
      <svg
        viewBox="0 0 320 180"
        preserveAspectRatio="xMidYMax slice"
        class="block size-full"
        xmlns="http://www.w3.org/2000/svg"
      >
        <defs>
          <linearGradient id="login-sky" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stop-color="#120e3d" />
            <stop offset="0.55" stop-color="#271d6b" />
            <stop offset="0.88" stop-color="#4a2f86" />
            <stop offset="1" stop-color="#7a4486" />
          </linearGradient>
          <radialGradient id="login-horizon" cx="0.5" cy="1" r="0.7">
            <stop offset="0" stop-color="#ff9d5c" stop-opacity="0.5" />
            <stop offset="1" stop-color="#ff9d5c" stop-opacity="0" />
          </radialGradient>
          <radialGradient id="login-moonglow">
            <stop offset="0" stop-color="#ffe9a8" stop-opacity="0.55" />
            <stop offset="1" stop-color="#ffe9a8" stop-opacity="0" />
          </radialGradient>
          <linearGradient id="login-streak" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0" stop-color="#ffffff" stop-opacity="0" />
            <stop offset="1" stop-color="#ffffff" stop-opacity="0.95" />
          </linearGradient>
          <linearGradient id="login-bowl" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stop-color="#ffb468" />
            <stop offset="1" stop-color="#e5702a" />
          </linearGradient>
          <linearGradient id="login-hood" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0" stop-color="#ffc884" />
            <stop offset="1" stop-color="#ee8738" />
          </linearGradient>
          <mask id="login-moon-mask">
            <rect width="320" height="180" fill="#fff" />
            <circle cx="262" cy="38" r="17" fill="#000" />
          </mask>
          <symbol id="login-sparkle" viewBox="-5 -5 10 10" overflow="visible">
            <path d="M0,-5 L1.3,-1.3 L5,0 L1.3,1.3 L0,5 L-1.3,1.3 L-5,0 L-1.3,-1.3Z" />
          </symbol>
          <path
            id="login-heart"
            d="M0,5 C-9,-1 -7,-9 -2.2,-8.6 C-0.8,-8.4 0,-7.4 0,-6.6 C0,-7.4 0.8,-8.4 2.2,-8.6 C7,-9 9,-1 0,5Z"
          />
        </defs>

        <%!-- Sky, horizon glow --%>
        <rect width="320" height="180" fill="url(#login-sky)" />
        <rect y="90" width="320" height="90" fill="url(#login-horizon)" />

        <%!-- Stars --%>
        <g :for={{x, y, scale, delay, color} <- @stars} transform={"translate(#{x} #{y})"}>
          <use
            href="#login-sparkle"
            width="10"
            height="10"
            x="-5"
            y="-5"
            fill={color}
            class="login-twinkle"
            style={"--d: #{delay}s; --s: #{scale}"}
          />
        </g>
        <circle
          :for={{x, y, delay} <- @dots}
          cx={x}
          cy={y}
          r="1"
          fill="#fff"
          class="login-twinkle"
          style={"--d: #{delay}s; --s: 1"}
        />

        <%!-- Shooting star: crosses the sky now and then --%>
        <g transform="translate(40 14)">
          <g class="login-shoot">
            <line
              x1="-34"
              y1="-13"
              x2="0"
              y2="0"
              stroke="url(#login-streak)"
              stroke-width="1.8"
              stroke-linecap="round"
            />
            <circle r="1.9" fill="#fff" />
          </g>
        </g>

        <%!-- Moon + halo --%>
        <circle cx="252" cy="44" r="46" fill="url(#login-moonglow)" class="login-halo" />
        <g class="login-bob" style="--dur: 7s">
          <circle cx="252" cy="44" r="20" fill="#ffe08a" mask="url(#login-moon-mask)" />
        </g>

        <%!-- Clouds --%>
        <g fill="#fff" opacity="0.1">
          <g transform="translate(70 78)">
            <g class="login-drift" style="--dur: 18s; --dx: 26px">
              <ellipse rx="24" ry="7" />
              <circle cx="-9" cy="-5" r="7" />
              <circle cx="6" cy="-8" r="9" />
            </g>
          </g>
          <g transform="translate(228 96)">
            <g class="login-drift" style="--dur: 22s; --dx: -22px">
              <ellipse rx="20" ry="6" />
              <circle cx="-7" cy="-4" r="6" />
              <circle cx="5" cy="-7" r="8" />
            </g>
          </g>
        </g>

        <%!-- Hills --%>
        <path
          d="M0,138 C60,122 112,134 164,128 C224,121 272,134 320,126 L320,180 L0,180Z"
          fill="#231b5e"
        />
        <path
          d="M0,166 C70,154 130,162 190,158 C245,155 290,162 320,158 L320,180 L0,180Z"
          fill="#150f3f"
        />

        <%= if @variant == :night do %>
          <.night_scene />
        <% else %>
          <.mail_scene />
        <% end %>
      </svg>
    </div>
    """
  end

  # Cradle with a sleeping baby, Zzz, and the floating heart / vitamin D drop.
  defp night_scene(assigns) do
    ~H"""
    <%!-- Floating keepsakes --%>
    <g transform="translate(56 100)">
      <g class="login-bob" style="--dur: 5s; --delay: 0.4s">
        <use href="#login-heart" fill="#ff7fa3" />
      </g>
    </g>
    <g transform="translate(264 118)">
      <g class="login-bob" style="--dur: 6s; --delay: 1s">
        <path
          d="M0,-9 C5,-2 8,2 8,6 C8,10 4,12.5 0,12.5 C-4,12.5 -8,10 -8,6 C-8,2 -5,-2 0,-9Z"
          fill="#ffd24a"
        />
        <path
          d="M-3.6,5 C-3.6,7.2 -2.2,8.6 -0.5,9"
          stroke="#fff6cf"
          stroke-width="1.6"
          stroke-linecap="round"
          fill="none"
        />
      </g>
    </g>

    <%!-- Cradle (hop on hover, rock always) --%>
    <g class="login-hop">
      <g class="login-cradle">
        <path
          d="M106,148 Q160,176 214,148"
          fill="none"
          stroke="#8f4a1d"
          stroke-width="5"
          stroke-linecap="round"
        />
        <%!-- hood interior --%>
        <path d="M112,113 C110,88 128,78 144,80 C140,90 139,102 140,113Z" fill="#b5561c" />
        <%!-- baby --%>
        <circle cx="152" cy="103" r="13.5" fill="#ffdcc8" />
        <path
          d="M151,90.5 q3,-5 6.5,-1.5"
          fill="none"
          stroke="#8a5a3a"
          stroke-width="2"
          stroke-linecap="round"
        />
        <path
          d="M146,103 q2.5,2.6 5,0 M154,103 q2.5,2.6 5,0 M151.5,109 q1.5,1.3 3,0"
          fill="none"
          stroke="#5a3a2a"
          stroke-width="1.4"
          stroke-linecap="round"
        />
        <circle cx="145.5" cy="108" r="2.6" fill="#ff9fb2" opacity="0.55" />
        <circle cx="160" cy="108" r="2.6" fill="#ff9fb2" opacity="0.55" />
        <%!-- blanket --%>
        <path
          d="M160,109 C168,101 178,110 188,104 C198,99 206,104 210,108 L210,120 L160,120Z"
          fill="#bba2ff"
        />
        <path
          d="M160,115 C168,107 178,116 188,110 C198,105 206,110 210,114"
          fill="none"
          stroke="#e4d8ff"
          stroke-width="2"
          stroke-linecap="round"
        />
        <circle cx="168" cy="107" r="4" fill="#ffdcc8" />
        <%!-- bowl --%>
        <path
          d="M112,112 H208 C208,138 190,154 160,154 C130,154 112,138 112,112Z"
          fill="url(#login-bowl)"
        />
        <path
          d="M114,125 H206"
          stroke="#fff2dd"
          stroke-opacity="0.55"
          stroke-width="2"
          stroke-dasharray="4 3"
          fill="none"
        />
        <use
          href="#login-sparkle"
          x="135"
          y="129"
          width="10"
          height="10"
          fill="#fff4d6"
          opacity="0.85"
        />
        <use
          href="#login-sparkle"
          x="155"
          y="134"
          width="10"
          height="10"
          fill="#fff4d6"
          opacity="0.85"
        />
        <use
          href="#login-sparkle"
          x="175"
          y="129"
          width="10"
          height="10"
          fill="#fff4d6"
          opacity="0.85"
        />
        <path d="M107,112 H213" stroke="#ffd9a8" stroke-width="5" stroke-linecap="round" />
        <%!-- hood canopy --%>
        <path d="M107,113 C104,82 124,70 146,73 C141,84 140,99 141,113Z" fill="url(#login-hood)" />
        <path
          d="M113,108 C112,90 124,80 138,78"
          fill="none"
          stroke="#fff2dd"
          stroke-opacity="0.5"
          stroke-width="2"
          stroke-linecap="round"
        />
      </g>
    </g>

    <%!-- Zzz --%>
    <g fill="#e9e0ff" font-weight="800" font-family="ui-sans-serif, system-ui, sans-serif">
      <text x="166" y="86" font-size="9" class="login-z" style="--d: 0s">Z</text>
      <text x="172" y="78" font-size="12" class="login-z" style="--d: 1s">Z</text>
      <text x="180" y="68" font-size="15" class="login-z" style="--d: 2s">Z</text>
    </g>

    <%!-- Tap hearts --%>
    <g transform="translate(160 88)" fill="#ff7fa3">
      <use href="#login-heart" class="login-pop" style="--x: -34px; --d: 0s" />
      <use href="#login-heart" class="login-pop" style="--x: 4px; --d: 0.12s" />
      <use href="#login-heart" class="login-pop" style="--x: 38px; --d: 0.24s" />
    </g>
    """
  end

  # A floating envelope: the code slip types itself in, a dashed trail leads in.
  defp mail_scene(assigns) do
    ~H"""
    <path
      d="M24,52 Q84,12 138,66"
      fill="none"
      stroke="#ffd9a0"
      stroke-opacity="0.7"
      stroke-width="2"
      stroke-linecap="round"
      stroke-dasharray="2 7"
      class="login-trail"
    />

    <g transform="translate(160 100)">
      <g class="login-float">
        <%!-- open flap behind the slip --%>
        <path d="M-42,-14 L0,-42 L42,-14Z" fill="#ffd9a8" />
        <%!-- slip with the code dots --%>
        <g class="login-slip">
          <rect x="-28" y="-38" width="56" height="48" rx="5" fill="#fffdf8" />
          <g fill="#f59a4a">
            <circle cx="-17.5" cy="-22" r="3.1" class="login-dot" style="--d: 0s" />
            <circle cx="-10.5" cy="-22" r="3.1" class="login-dot" style="--d: 0.18s" />
            <circle cx="-3.5" cy="-22" r="3.1" class="login-dot" style="--d: 0.36s" />
            <circle cx="3.5" cy="-22" r="3.1" class="login-dot" style="--d: 0.54s" />
            <circle cx="10.5" cy="-22" r="3.1" class="login-dot" style="--d: 0.72s" />
            <circle cx="17.5" cy="-22" r="3.1" class="login-dot" style="--d: 0.9s" />
          </g>
          <rect x="-20" y="-8" width="40" height="3" rx="1.5" fill="#e9dcc8" />
          <rect x="-14" y="-1" width="28" height="3" rx="1.5" fill="#e9dcc8" />
        </g>
        <%!-- envelope front --%>
        <path
          d="M-42,-14 L0,12 L42,-14 L42,38 Q42,46 34,46 H-34 Q-42,46 -42,38Z"
          fill="#fff1dc"
        />
        <path
          d="M-42,-14 L0,12 L42,-14"
          fill="none"
          stroke="#f0d3a8"
          stroke-width="2"
          stroke-linejoin="round"
        />
        <g transform="translate(0 20)">
          <use href="#login-heart" fill="#ff7fa3" class="login-beat" />
        </g>
      </g>
    </g>

    <use
      href="#login-sparkle"
      x="106"
      y="46"
      width="12"
      height="12"
      fill="#fff3c4"
      class="login-twinkle"
      style="--d: 0.2s; --s: 1"
    />
    <use
      href="#login-sparkle"
      x="212"
      y="70"
      width="10"
      height="10"
      fill="#ffffff"
      class="login-twinkle"
      style="--d: 1.1s; --s: 1"
    />
    <use
      href="#login-sparkle"
      x="226"
      y="120"
      width="8"
      height="8"
      fill="#ffe29a"
      class="login-twinkle"
      style="--d: 1.9s; --s: 1"
    />

    <%!-- Tap hearts --%>
    <g transform="translate(160 96)" fill="#ff7fa3">
      <use href="#login-heart" class="login-pop" style="--x: -34px; --d: 0s" />
      <use href="#login-heart" class="login-pop" style="--x: 4px; --d: 0.12s" />
      <use href="#login-heart" class="login-pop" style="--x: 38px; --d: 0.24s" />
    </g>
    """
  end
end
