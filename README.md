# Trygg

A low-friction, mobile-first newborn tracker. The point of the app is **shared
state**: either caregiver glances at their phone and instantly sees what the
other just logged — bottle feeds, diapers, sleep, height and weight — with
one-tap presets and a start/stop sleep timer.

Built with Phoenix LiveView. Realtime sync is Phoenix PubSub over the LiveView
socket (topic per child). Installable as a PWA with a true-black dark mode for
night feeds.

## Running it

```bash
mix setup
mix phx.server
```

Visit [`localhost:4000`](http://localhost:4000). Sign-in is passwordless — enter
your email, click the link. Sessions last a year, so you sign in once. In
development the email lands in the
[mailbox preview](http://localhost:4000/dev/mailbox).

The Reports tab's "Download PDF report" renders through headless Chrome
([ChromicPDF](https://hexdocs.pm/chromic_pdf)), so install Google Chrome or
Chromium locally; it's auto-detected on macOS and Linux. Chrome is started per
print job, so nothing else needs it. The production image installs Alpine's
`chromium` package. The end-to-end PDF test is opt-in: `mix test --include chrome`.

## Production email

Outbound mail goes through [Resend](https://resend.com). Because login is
passwordless, a working mailer is not optional — the release refuses to boot
without it. Set two secrets:

| Variable | What |
| --- | --- |
| `RESEND_API_KEY` | API key from [resend.com/api-keys](https://resend.com/api-keys) (`re_…`) |
| `MAIL_FROM` | Sender on a domain verified in Resend. Bare (`hello@trygg.app`) or named (`Trygg <hello@trygg.app>`). Defaults to Resend's shared `onboarding@resend.dev` sandbox sender, which only delivers to the Resend account owner. |

```bash
fly secrets set RESEND_API_KEY=re_xxx MAIL_FROM="Trygg <hello@trygg.app>"
```

The wiring lives in `config/runtime.exs` (adapter + key) and `config/prod.exs`
(the Req-based API client); `Trygg.Mailer.from_address/0` resolves `MAIL_FROM`.

## Shape of the code

| Area | Module | Notes |
| --- | --- | --- |
| Children, caregivers, invites | `Trygg.Families` | scope-first; roles `owner > caregiver > viewer` |
| The shared event log + timers + broadcasts | `Trygg.Log` | `subscribe/1`, `summary/2`, `start_timer/4`, `stop_timer/3` |
| Sleep calendars, trends, predictions, and alerts | `Trygg.Reports` | Today / 7-day / Trends on the Reports tab; `Reports.{Insights,Feeding,Diapers,Shifts,Alerts}` are pure functions over `Reports.Day`; `Reports.outlook/3` feeds the Home cards |
| Height and weight over time | `Trygg.Growth` | stored as grams / centimetres; Vitals tab plots CDC 2000 infant (birth–36 months) 5th–95th percentiles when the child's sex is girl or boy; `Growth.Velocity` turns pairs of weights into g/week, percentile movement and newborn loss/regain |
| Unit display (metric ⇄ imperial, stored metric) | `Trygg.Units` | per-user preference on `users.unit_system` |
| Child resolution / PubSub subscribe for LiveViews | `TryggWeb.ChildScope` | `on_mount` hook in the authenticated `live_session` |
| Screens | `TryggWeb.{Dashboard,Timeline,Vitals,Reports,Caregiver,Invite,Preferences,ChildLive.Index}Live` | |

Run the checks with `mix precommit`.

## Production

Hosted on [Fly.io](https://fly.io) (`track.backmanwong.family`). Deploys from `main` via GitHub Actions after compile, format, Sobelow, and tests. Locally: `make deploy-prod`.

Set these as Fly secrets before the first boot (`fly secrets set ...`). The release refuses to start without the ones marked required.

| Variable | Required | What |
| --- | --- | --- |
| `SECRET_KEY_BASE` | yes | Cookie signing/encryption. `mix phx.gen.secret` |
| `DATABASE_URL` | yes | Postgres URL (`fly pg attach` writes this) |
| `RESEND_API_KEY` | yes | Resend API key (`re_…`) — login is passwordless |
| `MAIL_FROM` | no | Sender on a domain verified in Resend. Defaults to the Resend sandbox address, which only delivers to the account owner |
| `RELEASE_COOKIE` | yes for clustering | Shared Erlang cookie. `mix phx.gen.secret` |
| `PHX_HOST` | set in `fly.toml` | Public hostname (`track.backmanwong.family`) |
| `POOL_SIZE` | set in `fly.toml` | Ecto pool size (default 10) |

```bash
fly secrets set SECRET_KEY_BASE="$(mix phx.gen.secret)" RELEASE_COOKIE="$(mix phx.gen.secret)"
fly secrets set RESEND_API_KEY=re_xxx MAIL_FROM="Trygg <hello@trygg.app>"
```

`GET /health` is the Fly HTTP check (plain `ok`, hits Postgres). TLS terminates at Fly; the app sets HSTS and treats `X-Forwarded-Proto` as the client scheme. LiveView origin checks follow the request host so the custom domain and `*.fly.dev` both work.

## Production email

## Insights and evidence

Everything predictive is computed from the child's own log, in memory, on
every refresh — nothing is persisted and there are no fixed-age "regression"
alerts. Population numbers appear only as labelled fallbacks (`typical for
age`) or as safety floors, and every alert card carries a one-line "not
medical advice" note.

| Insight | Where | How | Basis |
| --- | --- | --- | --- |
| Next nap, wake pressure | Home, Reports → Trends | Personal median wake window per nap ordinal over the last 14 days, shown with its IQR range; age-band prior when history is thin | No validated wake-window table exists — published charts disagree by 2×, so the child's own pattern wins |
| Next feed, feeds/day, volume | Home, Trends | Feeds < 30 min apart merge into one episode; median interval split by the child's day/night; cluster note at ≥ 3 feeds in 2 h. A late feed is framed as "later than usual", never "overdue" — the estimate is the child's rhythm, not a schedule | Descriptive, personal baseline; responsive-feeding guidance (AAP, Johns Hopkins) |
| Typical for age | Trends | Feeds/day and ml/feed by age band shown beside the child's own numbers, always labelled "typical for age" | Johns Hopkins / Stanford Children's "Feeding Guide for the First Year"; CDC formula-feeding guidance |
| Intake guide | Trends | 3-day average vs 150–180 / 120–150 / 100–120 ml/kg/day by age, needs a weight ≤ 14 days old; informational only | AAP / HealthyChildren formula guidance |
| Hydration | Home, Trends | Wet diapers per day vs the child's 7-day median and same-time-of-day pace; floors: < 6 wet/day, ≥ 6 dry hours (newborn day-of-life ramp) | AAP dehydration signs |
| Sleep shift | Home, Trends → Changes | Last 3 complete days vs the 14 before, robust z (median/MAD) with absolute floors on night wakings, night stretch, total sleep, naps | Change detection, not prediction; population data show no age-pinned regressions |
| Growth burst signal | Home, Trends, Vitals | Total sleep ≥ baseline + max(2 h, 1.5·IQR) or ≥ 2 extra naps on the last day or two, optionally + 20 % milk | Lampl & Johnson, *Sleep* 2011 (sleep bursts preceded length saltations by 0–4 days) |
| Weight gain | Vitals | g/day between the latest weight and one 7–35 days earlier; Δz from the CDC LMS tables; "expected gain to hold the percentile"; flag when Δz ≤ −0.67 over ≥ 14 days | CDC 2000 LMS; Merck / Mayo g/day ranges as a fallback |
| Newborn checks | Vitals, Home | Birth weight = measurement dated on the birth date; > 10 % loss in week one; regain by day 14 | Standard newborn guidance |

Deliberately excluded: sleep–feed causal correlations ("cap the afternoon
bottle → longer nights"), fixed-age regression alerts, "growth spurt in N
days" forecasts, WHO velocity tables (CDC stays), and push notifications (the
cards are PubSub-driven, in-app only).

## Not in this version

WHO 0–24 month growth charts (CDC 2000 infant percentiles are on Vitals), health & medication reminders, the milestone
scrapbook, daily photos, and PDF/CSV pediatrician exports. Native lock-screen
widgets need a companion native app and are out of scope for the web build.
