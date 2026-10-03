# Trygg diaper button (M5Stack Basic)

Three buttons, one tap each: **A = 💧 PEE**, **B = 💩 POO**, **C = 💧💩 MIXED**.
The screen shows the child's name on top and the emoji above each button. A press
POSTs a `diaper` entry to the [REST API](../docs/api.md) with a family API token;
it shows up live in the app for everyone in the family.

Feedback: the moment a button is let go the whole screen turns green for 4 seconds with the
emoji, "PEE logged" and the local time, and plays a little rising chime. Buttons are ignored
while it's up, so a fumbled double tap can't log twice.

## Battery: WiFi is off until there's something to send

The press is only *queued* at that moment; delivery happens in the background (a sync task on
the other CPU core, so the buttons never wait on the network):

1. A press puts `{child, kind, time, client_id}` on a queue and wakes the sync task.
2. The task switches WiFi on, joins (rejoining the last access point directly, which skips
   the channel scan), makes sure the clock is set, and POSTs the queue oldest first.
3. Presses made while it's running join the same WiFi session: the task re-checks the queue
   before it lets go. Otherwise a later press simply starts a new cycle.
4. WiFi goes off again and the device waits for the next press.

Entries are stamped with when the button was pressed, not when they were delivered. The
clock keeps running with WiFi off and is re-synced over NTP on every join. Each press has its
own `client_id`, so a retry after a lost response can never log the same change twice.

If the network or server is out of reach the entries stay queued (up to 20, in RAM) and the
banner reads "N waiting to send"; the retry interval doubles from 15 s up to 5 min, and the
next press retries at once. An entry the server rejects outright (`Bad token`, `Token is
read-only`, `Child not found`…) is dropped and the banner says why, with a low beep. A press
before the first successful connection after boot is refused ("Not connected yet"), since
there's no child to log it for yet.

A power cut or reset loses whatever is still queued.

## Night mode

From 8 PM to 8 AM (local time, per `TIMEZONE`) the screen is dimmed to a low backlight so it
doesn't light up the room, including the green "logged" screen; it comes back at 8 AM. Until the
clock has synced after boot the brightness is left at the daytime level. The hours and levels are
constants at the top of `src/main.cpp`.

## Switching children

A tap logs when the button is let go. Holding a button for about a second does this instead
(and logs nothing):

| Hold          | Does                                                                         |
| ------------- | ---------------------------------------------------------------------------- |
| **A** (left)  | previous child                                                               |
| **C** (right) | next child (both wrap around)                                                |
| **B** (middle)| opens a list: **A** ▲, **C** ▼, **B** selects; closes by itself after 10 s   |

The device remembers its pick across reboots. `TRYGG_CHILD_ID` only decides the starting
child: edit it and re-flash and that wins over the remembered pick.

## Local dev setup

The device talks to your Mac over WiFi, so the dev server must listen on the LAN.

```sh
make fw-config          # writes firmware/include/config.h: LAN IP, timezone + a fresh dev token
$EDITOR firmware/include/config.h   # set WIFI_SSID / WIFI_PASSWORD (2.4 GHz only)
make dev-lan            # dev server on 0.0.0.0 (PORT=4012 make dev-lan if 4000 is taken)
make fw-flash           # build + flash over USB-C
make fw-monitor         # optional serial monitor
```

If you change `PORT`, set the same port in `TRYGG_URL`. `firmware/tools/smoke_test.sh`
makes the device's API calls from the Mac (`--read-only` to skip creating entries).

`config.h` holds the WiFi password and token and is gitignored. Tokens come from
`mix trygg.dev_token` locally, or the **Sharing → API access** page (give it "Read and
log" access) for a real server. Point `TRYGG_URL` at an `https://` address and the
certificate is verified against the CA bundle built into the Arduino core.

## Notes

- The children (names, new child) are refreshed on a sync when they're over an hour old; the
  device never wakes WiFi just for that.
- The first build downloads the ESP32 toolchain (~1 GB, cached in `~/.platformio`).
  `make` creates the Python venv in `firmware/.venv` on demand.
- Icons are rendered from the macOS emoji font into `src/icons.h` (`make fw-icons`);
  the screen can't draw colour emoji itself.
- Upload speed is 460800 baud; 921600 fails on this board's CP2104.
