defmodule TryggWeb.LoginComponents do
  @moduledoc """
  The animated night sky behind the signed-out login screen.

  Two pieces, both animated purely with CSS (`.login-*` rules in app.css) so
  they cost no extra requests and every motion switches off under
  `prefers-reduced-motion`:

    * `login_sky/1` is a fixed, full-viewport backdrop (stars, moon, clouds,
      rising hearts, hills). It is laid out in percentages and viewport units
      rather than one fixed-aspect picture, so it fills a phone, a tablet and a
      desktop alike without cropping the interesting bits.
    * `login_hero/1` is the character in the page flow above the cards: a baby
      asleep in a cradle on a cloud, or an envelope with a code typing itself
      in.

  The sky paints its own fixed dusk-to-night colors rather than theme tokens,
  so it looks right under both the warm light theme and the true-black dark
  one. Page copy that sits directly on it is white.

  The one bit of JS is the `LoginScene` hook, which only restarts a CSS
  animation when the hero is tapped.
  """
  use Phoenix.Component

  # Scattered across the sky as {x%, y%, size-px, delay-s, color, kind}. A
  # golden-ratio sequence spreads them evenly without clumping, and keeps the
  # layout deterministic (no random flicker between renders).
  @stars (for i <- 1..40 do
            fract = fn v -> v - Float.floor(v) end
            colors = ["#fff3c4", "#ffffff", "#ffe29a", "#ffffff"]

            {
              Float.round(fract.(i * 0.618034) * 100, 1),
              Float.round(fract.(i * 0.414214 + 0.13) * 76, 1),
              if(rem(i, 3) == 0, do: 6 + rem(i * 7, 8), else: 2),
              Float.round(fract.(i * 0.37) * 4, 1),
              Enum.at(colors, rem(i, 4)),
              if(rem(i, 3) == 0, do: :sparkle, else: :dot)
            }
          end)

  # Little hearts drifting up the whole screen: {left%, size-px, duration-s, delay-s}.
  # Negative delays so a few are already mid-flight when the page loads.
  @hearts [
    {7, 14, 19, -3},
    {21, 10, 24, -11},
    {36, 16, 17, -7},
    {52, 11, 26, -17},
    {66, 13, 20, -1},
    {80, 9, 23, -14},
    {92, 15, 18, -9}
  ]

  @doc """
  The fixed full-screen sky. Render it once, inside a stacking context (the
  login page's `isolate` wrapper), before the page content.
  """
  def login_sky(assigns) do
    assigns = assign(assigns, stars: @stars, hearts: @hearts)

    ~H"""
    <div
      id="login-sky"
      class="login-sky pointer-events-none fixed inset-0 -z-10 m-0 overflow-hidden"
      aria-hidden="true"
    >
      <%!-- Shared gradients and shapes. Referenced by `url(#…)` / `<use>` from
           this sky and from the hero, so it is a real (0x0) svg rather than a
           display:none one, which some browsers won't resolve gradients from. --%>
      <svg width="0" height="0" class="absolute" focusable="false">
        <defs>
          <linearGradient id="login-bowl" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stop-color="#ffb468" />
            <stop offset="1" stop-color="#e5702a" />
          </linearGradient>
          <linearGradient id="login-hood" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0" stop-color="#ffc884" />
            <stop offset="1" stop-color="#ee8738" />
          </linearGradient>
          <linearGradient id="login-cloudfill" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stop-color="#ffffff" />
            <stop offset="1" stop-color="#cdc0f2" />
          </linearGradient>
          <radialGradient id="login-herohalo">
            <stop offset="0" stop-color="#9a86ff" stop-opacity="0.42" />
            <stop offset="1" stop-color="#9a86ff" stop-opacity="0" />
          </radialGradient>
          <radialGradient id="login-moonglow">
            <stop offset="0" stop-color="#ffe9a8" stop-opacity="0.55" />
            <stop offset="1" stop-color="#ffe9a8" stop-opacity="0" />
          </radialGradient>
          <symbol id="login-sparkle" viewBox="-5 -5 10 10" overflow="visible">
            <path d="M0,-5 L1.3,-1.3 L5,0 L1.3,1.3 L0,5 L-1.3,1.3 L-5,0 L-1.3,-1.3Z" />
          </symbol>
          <path
            id="login-heart"
            d="M0,5 C-9,-1 -7,-9 -2.2,-8.6 C-0.8,-8.4 0,-7.4 0,-6.6 C0,-7.4 0.8,-8.4 2.2,-8.6 C7,-9 9,-1 0,5Z"
          />
        </defs>
      </svg>

      <div class="login-horizon absolute inset-0"></div>

      <%!-- Stars --%>
      <span
        :for={{x, y, size, delay, color, kind} <- @stars}
        class={["login-star", kind == :dot && "login-star-dot"]}
        style={"left: #{x}%; top: #{y}%; width: #{size}px; --d: #{delay}s; --c: #{color}"}
      >
      </span>

      <%!-- A shooting star every now and then --%>
      <span class="login-shoot"></span>

      <%!-- Moon + halo --%>
      <svg
        viewBox="0 0 100 100"
        class="login-moon absolute right-[7%] top-[max(5dvh,env(safe-area-inset-top))] size-[clamp(72px,17vmin,128px)]"
      >
        <defs>
          <mask id="login-moon-mask">
            <rect width="100" height="100" fill="#fff" />
            <circle cx="60" cy="42" r="17" fill="#000" />
          </mask>
        </defs>
        <circle cx="50" cy="50" r="48" fill="url(#login-moonglow)" class="login-halo" />
        <g class="login-bob" style="--dur: 7s">
          <circle cx="50" cy="50" r="20" fill="#ffe08a" mask="url(#login-moon-mask)" />
        </g>
      </svg>

      <%!-- Clouds drifting across the sky --%>
      <svg
        viewBox="-30 -16 60 24"
        class="login-cloud absolute left-[6%] top-[24%] w-24"
        style="--dur: 70s; --dx: 34vw"
      >
        <g fill="#fff" opacity="0.1">
          <ellipse rx="24" ry="7" />
          <circle cx="-9" cy="-5" r="7" />
          <circle cx="6" cy="-8" r="9" />
        </g>
      </svg>
      <svg
        viewBox="-30 -16 60 24"
        class="login-cloud absolute left-[58%] top-[44%] w-28"
        style="--dur: 90s; --dx: -40vw"
      >
        <g fill="#fff" opacity="0.08">
          <ellipse rx="22" ry="6.5" />
          <circle cx="-8" cy="-4" r="6.5" />
          <circle cx="6" cy="-7" r="8.5" />
        </g>
      </svg>
      <svg
        viewBox="-30 -16 60 24"
        class="login-cloud absolute left-[22%] top-[66%] w-20"
        style="--dur: 80s; --dx: 30vw"
      >
        <g fill="#fff" opacity="0.07">
          <ellipse rx="22" ry="6.5" />
          <circle cx="-8" cy="-4" r="6.5" />
          <circle cx="6" cy="-7" r="8.5" />
        </g>
      </svg>

      <%!-- Hearts drifting up the screen --%>
      <svg
        :for={{left, size, dur, delay} <- @hearts}
        viewBox="-9 -9 18 18"
        class="login-rising"
        style={"left: #{left}%; width: #{size}px; --dur: #{dur}s; --delay: #{delay}s"}
      >
        <use href="#login-heart" fill="#ff7fa3" />
      </svg>

      <%!-- Hills along the bottom --%>
      <svg
        viewBox="0 0 320 60"
        preserveAspectRatio="none"
        class="absolute inset-x-0 bottom-0 h-[clamp(72px,15dvh,170px)] w-full"
      >
        <path d="M0,22 C60,6 112,18 164,12 C224,5 272,18 320,10 L320,60 L0,60Z" fill="#231b5e" />
        <path d="M0,46 C70,34 130,42 190,38 C245,35 290,42 320,38 L320,60 L0,60Z" fill="#150f3f" />
      </svg>
    </div>
    """
  end

  @doc """
  The character above the cards. `variant` is `:night` (a baby asleep in a
  rocking cradle, for the email step) or `:mail` (an envelope with a code
  typing itself in, for the "check your email" step). Tapping it pops hearts.
  """
  attr :variant, :atom, values: [:night, :mail], default: :night

  def login_hero(assigns) do
    ~H"""
    <div
      id={"login-scene-#{@variant}"}
      phx-hook="LoginScene"
      phx-update="ignore"
      aria-hidden="true"
      class="login-hero login-scene-in mx-auto aspect-square w-[min(60vw,26dvh,14rem)] cursor-pointer select-none"
    >
      <svg
        viewBox="88 28 152 152"
        class="block size-full overflow-visible"
        xmlns="http://www.w3.org/2000/svg"
      >
        <%= if @variant == :night do %>
          <.night_hero />
        <% else %>
          <.mail_hero />
        <% end %>
      </svg>
    </div>
    """
  end

  # Cradle on a cloud, with a sleeping baby, Zzz and a few keepsakes.
  defp night_hero(assigns) do
    ~H"""
    <%!-- Soft glow behind the cradle --%>
    <circle cx="160" cy="112" r="78" fill="url(#login-herohalo)" class="login-halo" />

    <%!-- Keepsakes --%>
    <g transform="translate(104 66)">
      <g class="login-bob" style="--dur: 5s; --delay: 0.4s">
        <use href="#login-heart" fill="#ff7fa3" />
      </g>
    </g>
    <g transform="translate(222 108)">
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
    <use
      href="#login-sparkle"
      x="214"
      y="52"
      width="9"
      height="9"
      fill="#fff3c4"
      class="login-twinkle"
      style="--d: 0.3s; --s: 1"
    />
    <use
      href="#login-sparkle"
      x="94"
      y="108"
      width="7"
      height="7"
      fill="#ffffff"
      class="login-twinkle"
      style="--d: 1.4s; --s: 1"
    />

    <%!-- The cloud the cradle rests on --%>
    <g class="login-bob" style="--dur: 8s; --delay: 0.8s">
      <g fill="url(#login-cloudfill)">
        <ellipse cx="160" cy="172" rx="70" ry="10" />
        <circle cx="116" cy="169" r="11" />
        <circle cx="136" cy="166" r="12" />
        <circle cx="184" cy="166" r="12" />
        <circle cx="205" cy="169" r="10" />
      </g>
    </g>

    <%!-- Cradle (hops on hover, rocks always) --%>
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

    <.pop_hearts y="88" />
    """
  end

  # A floating envelope: the code slip types itself in, a dashed trail leads in.
  defp mail_hero(assigns) do
    ~H"""
    <circle cx="160" cy="106" r="78" fill="url(#login-herohalo)" class="login-halo" />

    <path
      d="M90,66 Q112,38 142,64"
      fill="none"
      stroke="#ffd9a0"
      stroke-opacity="0.75"
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
      x="104"
      y="44"
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
      x="214"
      y="128"
      width="8"
      height="8"
      fill="#ffe29a"
      class="login-twinkle"
      style="--d: 1.9s; --s: 1"
    />

    <.pop_hearts y="96" />
    """
  end

  attr :y, :string, required: true

  defp pop_hearts(assigns) do
    ~H"""
    <g transform={"translate(160 #{@y})"} fill="#ff7fa3">
      <use href="#login-heart" class="login-pop" style="--x: -34px; --d: 0s" />
      <use href="#login-heart" class="login-pop" style="--x: 4px; --d: 0.12s" />
      <use href="#login-heart" class="login-pop" style="--x: 38px; --d: 0.24s" />
    </g>
    """
  end
end
