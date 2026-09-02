# Trygg

A low-friction, mobile-first newborn tracker. The point of the app is **shared
state**: either caregiver glances at their phone and instantly sees what the
other just logged — bottle feeds, diapers, sleep — with one-tap presets and a
start/stop sleep timer.

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
| Unit display (metric ⇄ imperial, stored metric) | `Trygg.Units` | per-user preference on `users.unit_system` |
| Child resolution / PubSub subscribe for LiveViews | `TryggWeb.ChildScope` | `on_mount` hook in the authenticated `live_session` |
| Screens | `TryggWeb.{Dashboard,Timeline,Caregiver,Invite,Preferences,ChildLive.Index}Live` | |

Run the checks with `mix precommit`.

## Not in this version

Growth charts / WHO percentiles, health & medication reminders, the milestone
scrapbook, daily photos, and PDF/CSV pediatrician exports. Native lock-screen
widgets need a companion native app and are out of scope for the web build.
